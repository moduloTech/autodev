# Giving `mr-review` a timeout (Autodev #54)

Date: 2026-08-10
Ticket: Skynet Autodev #54 — "mr-review tourne sans timeout dans un état actif :
le silence de `reviewing` n'est borné par aucun réglage"

Follows: `2026-08-10-live-worker-silence-invariant-design.md` (Autodev #50),
whose final review found this gap and closed half of it.

## Problem

`DormantAudit`'s active arm repositions a row in `Issue::STALLED_STATES` that has
produced no `activity_events` row for `HealthReport#stuck_active_after`, using
`update_all` from the poll cycle — outside the `limits_concurrency` that
serialises `IssueProcessJob`. #50 made that safe by bounding a live worker's
silence two ways: a heartbeat row per danger-claude call, and a window derived
from the longest configured timeout.

`reviewing` escaped both. `mr-review` is an LLM review of the full MR diff, run
via `Open3.capture3` with **no timeout**. #50 added `dc_heartbeat!('mr-review')`
immediately before the call, which bounds the state's silence at *one mr-review
run* instead of leaving it unbounded — but a run that never returns is still
unbounded, and no configured value sizes the window for it. #50's spec records
`reviewing` as an acknowledged exception for exactly that reason.

The exposure that remains: a wedged `mr-review` (process hung, pipe never
closed) keeps `reviewing` silent forever under a live worker. Past the window the
audit repositions the row to `checking_pipeline`; if the ticket is closed or
unassigned inside that window, `route` prefers those outcomes and the row goes
`closed`/`done` while the worker is still holding the lock — the failure mode #50
describes, on the one state #50 could not cover.

## Design

Smaller than the ticket anticipated, because two of its five steps turn out to be
unnecessary.

### 1. Route `mr-review` through `run_with_timeout`

`ProcessRunner#run_with_timeout` already owns everything this needs: it spawns
into its own process group, kills the group with TERM then KILL after a 5 s
grace, and folds stdout/stderr into the `@dc_stdout` / `@dc_stderr` diagnostic
buffers. In `PipelineMonitor::Reviewer#run_mr_review_command`:

```ruby
# lib/autodev/pipeline_monitor/reviewer.rb
def run_mr_review_command(mr_url)
  log "Running mr-review on #{mr_url}..."
  dc_heartbeat!('mr-review')
  # chdir: Dir.pwd preserves the previous behaviour — Open3.capture3 inherited
  # the process's cwd, and mr-review works through the GitLab API rather than in
  # a local clone, so it has no repo to sit in. run_with_timeout requires the
  # argument, so it is passed explicitly rather than left implicit.
  _, err, ok = run_with_timeout('mr-review', ['-H', mr_url], chdir: Dir.pwd, label: 'mr-review')
  return log('Review completed successfully') || true if ok

  log_error "mr-review failed (non-fatal): #{err[0, 300]}"
  false
end
```

The timeout is `dc_timeout` — `run_with_timeout` resolves
`@project_config['dc_timeout'] || @config['dc_timeout'] || 600`, and the global
is always the baked `Config::DEFAULTS` value (a `config.yml` global is in
`IGNORED_GLOBAL_FIELDS`). So the cap is 30 minutes by default, raisable per
project.

**One side effect inherited, and why it is benign.** `run_with_timeout` calls
`PortAllocator.release(@port_mappings) if @port_mappings` — a danger-claude
concern (freeing host ports so Docker can bind them), which a non-danger-claude
command now inherits. It cannot bite: `@port_mappings` is only ever set by
`dc_global_args`, no danger-claude call precedes the review inside one
`PipelineMonitor#check` (the pipeline evaluator runs on the red branch, the review
on the green one), and `PortAllocator.release` swallows per-socket errors, so even
a stale mapping would be a no-op. Worth stating rather than discovering: the
coupling is real, the exposure is not.

**Why not a dedicated setting.** The ticket proposed a per-project
`mr_review_timeout`. It would cost a `timeout:` kwarg on `run_with_timeout`, a
migration and column, `Project` validations plus `CONFIG_INTEGER_FIELDS` /
`SCALAR_CONFIG_KEYS` / `#to_project_config`, `Config::DB_BACKED_PROJECT_FIELDS`,
`ProjectValidator`, `YamlProjectImporter`, the project-edit form with its hint
and two i18n keys, and one more term in `longest_worker_timeout` — eight files
for a knob nobody has asked for, chosen against no data on how long reviews
actually take. Reusing `dc_timeout` costs nothing and makes step 3 below
disappear. If a project ever needs the two decoupled, the plumbing is mechanical
and the need will come with a number attached.

### 2. The non-fatal semantics already hold

The ticket asked that a timeout stay non-fatal and increment
`review_failure_count` rather than dropping the request into `error`. That
happens with no new code:

`run_with_timeout` **raises** `ImplementationError` on timeout (it does not
return a falsy status), and `Reviewer#execute_mr_review` already wraps the call
in `rescue StandardError => e` → `log_error "mr-review error (non-fatal)"` →
`false`. `launch_review` reads that `false` and calls `finalize_review_failure`,
which increments `review_failure_count`; at `REVIEW_FAILURE_THRESHOLD` (5) the
row goes `done` with `review_failures_exhausted`.

So the behaviour is a consequence of code that already exists. What is missing is
a test saying so — without one, a future refactor of `execute_mr_review`'s rescue
could turn a timeout into a hard failure and nothing would notice.

### 3. No change to `HealthReport`

The ticket's step 3 was "add the new timeout to `longest_worker_timeout`". Once
the cap is `dc_timeout`, that term is already there — `longest_worker_timeout`
maxes over `dc_timeout` and `post_completion_timeout` across DB rows, YAML
entries and the baked defaults. The derived window covers `reviewing` the moment
mr-review is bounded by `dc_timeout`, with `HealthReport` untouched.

The docs move in the opposite direction: `reviewing` **leaves** the exceptions
list.

- `docs/superpowers/specs/2026-08-10-live-worker-silence-invariant-design.md`
  §2's "Acknowledged exception: `reviewing`" paragraph is rewritten to record
  that #54 closed it, rather than deleted — the spec is the account of what was
  known when, and a reader following #50's reasoning needs to see where it went.
- `docs/observability.md`'s "Exception reconnue : `reviewing`" bullet is removed
  (French). `running_post_completion` remains the only exception, and it is
  covered by the arithmetic.

### 4. Delete the dead review path in `MrManager`

`IssueProcessor::MrManager#run_review` has **no caller** anywhere in `app/`,
`lib/`, `test/` or `bin/`; `#execute_review` is called only by it, and
`#command_exists?` only by those two. The trio is ~25 lines duplicating
`Reviewer`'s logic — the same `command_exists?` probe, the same 15 s sleep, the
same `Open3` shell-out — and it has already started to drift: #50 added a
heartbeat there for a call that will never execute.

All three are removed. `Reviewer` becomes the only review path, which it already
is in practice.

### Rejected: moving `dc_heartbeat!` into `run_with_timeout`

Its three callers (the two danger-claude entry points, plus mr-review after this
change) would then be covered from one place, and any future caller would get
liveness for free — precisely the generalization #50 claimed and did not have.

Rejected on test cost. The tests that pin the heartbeat
(`test/danger_claude_runner_heartbeat_test.rb`,
`test/pipeline_monitor_review_heartbeat_test.rb`) work by stubbing
`run_with_timeout` itself. Move the heartbeat inside it and those pins become
circular: they would have to reach down to `spawn_process`, supplying fake pipes
and a pid `Process.wait2` accepts. Three explicit call lines are worth more than
deeper, more brittle pins on code that shipped and was reviewed last week.

## Testing

TDD, one test per claim, extending `test/pipeline_monitor_review_heartbeat_test.rb`
(same `Harness` mixing in `DangerClaudeRunner` + `PipelineMonitor::Reviewer`).

- A timeout does not escape: with `run_with_timeout` stubbed to raise
  `ImplementationError`, `execute_mr_review` returns `false` and raises nothing.
  This is the contract `launch_review` branches on, and the assertion that keeps
  a timeout non-fatal.
- A timeout still leaves exactly one heartbeat row — the marker is written before
  the call, so the audit sees liveness up to the moment the process was killed.
- The success path returns `true` and the failure path (`ok == false`) returns
  `false`, both through `run_with_timeout` rather than `Open3.capture3`.
- `mr-review` is invoked with the timeout wrapper, not raw: the stub asserts the
  command and args (`'mr-review'`, `['-H', mr_url]`) reaching
  `run_with_timeout`. Without this, a revert to `Open3.capture3` would leave the
  other tests green.
- The two existing tests in that file are adapted: they stub `Open3.capture3`,
  which is no longer on the path.

`MrManager`'s deletion needs no new test — there is nothing to exercise. The full
suite must stay green, which is what proves nothing referenced it.

## Docs

- `CHANGELOG.md` `[Unreleased]`.
- `docs/observability.md` — drop the `reviewing` exception bullet.
- `docs/superpowers/specs/2026-08-10-live-worker-silence-invariant-design.md` —
  rewrite the exception paragraph to point here.
- `docs/usage/autodev-technical-usage.md` — the config-fields table documents
  `dc_timeout` as "délai max d'un appel `danger-claude`"; it now also caps
  `mr-review`, so the description changes.

## Constraints

CLAUDE.md: TDD, RuboCop green (`mise x ruby -- rubocop`, never edit
`.rubocop.yml`), Conventional Commits, `CHANGELOG.md` `[Unreleased]` updated in
the same pass, every user-facing string through `Locales.t` / `t_web` in both
`fr` and `en` (this change adds none). `docs/observability.md` is French and is
rendered through Redcarpet — no code span nested inside another.

## Out of scope

- A per-project `mr_review_timeout` (see §1 for the cost, and the condition under
  which it becomes worth it).
- Moving the heartbeat into `run_with_timeout` (see Rejected).
- `http.lowSpeedLimit` in `CLEAN_ENV` for the untimed git operations #50's final
  review inventoried (`clone`, `push`, rebase, the `clone_and_checkout` inside
  `running_post_completion`, screenshot uploads). None is a real risk today —
  `clone_depth` defaults to 1, so the failure mode is a wedged TCP connection,
  not a large repo — and the window's slack factor absorbs them. Recorded in #54
  as the natural companion, but it is a separate change with its own failure
  modes.

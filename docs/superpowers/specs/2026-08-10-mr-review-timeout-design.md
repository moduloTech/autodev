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

Close to what the ticket anticipated. Its step 5 (verify the timeout stays
non-fatal) turns out to need no code, only a test — the behaviour already holds.
Its step 2 (choose the setting) was first answered "reuse `dc_timeout`" and then
reversed on production data; see below.

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
  _, err, ok = run_with_timeout('mr-review', ['-H', mr_url], chdir: Dir.pwd,
                                timeout: mr_review_timeout)
  return log('Review completed successfully') || true if ok

  log_error "mr-review failed (non-fatal): #{err[0, 300]}"
  false
end
```

No `label:` is passed: `ProcessRunner` builds its tag as `"#{cmd} #{label}"`, so
`label: 'mr-review'` would read `mr-review mr-review timed out after 3600s`. The
other callers use `label` as a *sub-operation* discriminator (`'-p'`, `'-c'` →
`danger-claude -p`), and there is only one kind of mr-review call.

The cap comes from `mr_review_timeout` — `@project_config['mr_review_timeout'] ||
Config::MR_REVIEW_TIMEOUT` (3600) — passed through a new `timeout:` kwarg on
`run_with_timeout`, which otherwise keeps resolving `dc_timeout` for its two
danger-claude callers.

**One side effect inherited, and why it is benign.** `run_with_timeout` calls
`PortAllocator.release(@port_mappings) if @port_mappings` — a danger-claude
concern (freeing host ports so Docker can bind them), which a non-danger-claude
command now inherits. It cannot bite: `@port_mappings` is only ever set by
`dc_global_args`, no danger-claude call precedes the review inside one
`PipelineMonitor#check` (the pipeline evaluator runs on the red branch, the review
on the green one), and `PortAllocator.release` swallows per-socket errors, so even
a stale mapping would be a no-op. Worth stating rather than discovering: the
coupling is real, the exposure is not.

**Reversed after measurement: a dedicated per-project setting.** This design
first reused `dc_timeout` and argued a dedicated `mr_review_timeout` was a knob
"nobody has asked for, chosen against no data on how long reviews actually
take", adding that "the need will come with a number attached". The final review
went and got the number, from the production-copy DB — 317 completed reviews, all
on `powerpanne/core`, whose `dc_timeout` is NULL and therefore 1800 s:

| | duration |
|---|---|
| 263 of them | under 5 min |
| mean | 213 s |
| 20–30 min | **10 reviews** |
| longest | **2641 s (44 min), and it ended in `review_done` — a success** |
| second longest | 1752 s, 48 s under the cap |

A 1800 s cap would therefore have killed roughly one **successful** review in 317
— about one a quarter at current volume — with six more within seven minutes of
the edge, and review duration tracks MR size, which is not shrinking.

The blast radius makes that worse than a lost review. `review_count` is
incremented only on success, so the next poll re-enters `reviewing` and reruns
`mr-review` from scratch; five rounds later `give_up_reviewing` forces `done`,
sets `label_done`, reassigns the author, flags
`needs_attention: review_failures_exhausted` and notifies GitLab. The outcome is
a false "exhausted" alarm and **no review at all**, on precisely the large MRs
that most need one, having burned ~2.5 h of Claude quota.

So the plumbing is worth it: a per-project `mr_review_timeout`, baked default
`Config::MR_REVIEW_TIMEOUT = 3600` (covering every observed run), with
`run_with_timeout` gaining a `timeout:` kwarg and `longest_worker_timeout`
gaining a term. Note the term is window-neutral at the default —
`2 × 3600 = 7200`, exactly the existing floor — so §3's "no behaviour change at
the default configuration" still holds; what changes is that a project raising
its own review cap now widens the window automatically, which is the whole point
of the derivation.

Rejecting the setting was the right call **on the information the design had**;
the mistake was writing "no data" without looking for it, when a `SELECT` over
`activity_events` was available the whole time.

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

### 3. One term added to `HealthReport`

`longest_worker_timeout` maxes over `dc_timeout` and `post_completion_timeout`
across DB rows, YAML entries and the baked defaults; `mr_review_timeout` joins
them on all three. Window-neutral at the default (`2 × 3600 = 7200`, the existing
floor), and a project raising its own review cap widens the window automatically
— which is what makes `reviewing` covered rather than excepted.

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

- Moving the heartbeat into `run_with_timeout` (see Rejected).
- `http.lowSpeedLimit` in `CLEAN_ENV` for the untimed git operations #50's final
  review inventoried (`clone`, `push`, rebase, the `clone_and_checkout` inside
  `running_post_completion`, screenshot uploads). None is a real risk today —
  `clone_depth` defaults to 1, so the failure mode is a wedged TCP connection,
  not a large repo — and the window's slack factor absorbs them. Recorded in #54
  as the natural companion, but it is a separate change with its own failure
  modes.

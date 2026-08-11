# Bounding a live worker's silence (Autodev #50)

Date: 2026-08-10
Ticket: Skynet Autodev #50 — "L'audit dormant peut muter une demande sous un
worker vivant si `dc_timeout` dépasse `stuck_active_after`"

## Problem

`DormantAudit`'s active arm selects rows in `Issue::STALLED_STATES` with no
`activity_events` row for `stuck_active_after` (7200 s) and repositions them
through `Issue.revive_stalled!`. That pass runs inline in `AutodevPollJob` and
mutates by `update_all`, so it sits **outside** the `limits_concurrency to: 1,
key: "issue-<path>-<iid>"` that serialises `IssueProcessJob`. Nothing structural
stops it from writing to a row while a job holds the lock on it.

What makes that safe is an unwritten invariant:

> a worker that is still alive cannot stay silent for `stuck_active_after`.

`Issue.recover_on_startup!` never had this exposure — at boot, nothing is
running. The audit does.

### The invariant is already false, at default settings

#50 was filed on the assumption that no current configuration violates it
("`dc_timeout` is 1800 s, every worker emits activity more often than that").
That assumption does not hold for `fixing_pipeline`.

`PipelineFixer` emits `log_activity(:pipeline_fixing, count:)` **once** when it
enters the state, then loops over the N failed jobs. Each iteration makes **two**
danger-claude calls — `run_pipeline_fix_prompt` then `danger_claude_commit` — and
emits nothing in between. The next activity event is `:pipeline_fix_pushed`,
after the loop. So the longest silence in `fixing_pipeline` is:

```
N_jobs × 2 × dc_timeout      = N × 3600 s at the default dc_timeout of 1800
```

Two slow jobs reach the 7200 s window; three exceed it. danger-claude calls do
hit their timeout in practice — that is the documented reason the default was
raised from 600 s to 1800 s (CHANGELOG, trigger ticket powerpanne/core#16207).

`MrFixer` is the instructive contrast: `fix_each_discussion` emits
`log_activity(:discussion_fixing)` per discussion, so its silence is bounded at
`2 × dc_timeout` regardless of how many discussions there are. The difference
between the two loops is the whole bug.

The other states are under the window at default settings: `implementing` with
`parallel_agents` is a complexity eval followed by concurrent agents
(`2 × dc_timeout`), `split_implementation` runs its two passes in threads
(`1 × dc_timeout`), and every other danger-claude call sits in a state whose
entry and exit transitions both emit.

### What the violation costs

In the reachable case the damage is mild **by coincidence, not by design**:
`fixing_pipeline` ∈ `REVIVE_TO_PIPELINE`, so `revive_stalled!` moves the row to
`checking_pipeline` — the very state `pipeline_fix_done!` was about to reach. The
worker's in-memory AASM object still transitions validly and re-writes the same
status.

The design-level failure modes remain:

- If the ticket is closed or unassigned inside that window, `route` prefers those
  outcomes over re-arming: the row goes `closed` / `done` while the worker keeps
  pushing and can still open an MR the row no longer records. That is the
  "orphaned MR, no error line" outcome #50 describes.
- A pre-MR state (`implementing`, …) revives to `pending` + stamp, so
  `dispatch_retries` enqueues `:retry_stuck`. `limits_concurrency` makes it wait
  for the live job rather than run beside it, then replays a full implementation
  over the work that job just pushed. Not reachable at default settings today;
  reachable for any project that raises `dc_timeout`.
- `whiny_transitions: false` means every no-op transition is silent. Nothing
  logs, nothing errors.

And the general case reopens with any future loop that makes several
danger-claude calls without emitting per iteration.

### Why the config-only fix is not enough

The ticket proposed deriving `stuck_active_after` from `dc_timeout`. That covers
a single long call, but `N` — the number of failed pipeline jobs — is not known
at config-load time, so no formula over `dc_timeout` bounds `N × 2 ×
dc_timeout`. The invariant has to be made true where the calls happen, not only
sized around in the config.

### A second reader is affected

`stuck_active_after` also drives `HealthReport`'s "Issues bloquées" card, which
documents that "a long but live danger-claude run isn't flagged". Under the same
conditions that card is wrong too, and in the same direction. Widening the
window fixes both readers at once; a cross-validation between two settings would
leave the card lying in the edge case.

## Design

Two parts. Part 1 makes the invariant true; part 2 makes the remaining
dependency explicit instead of coincidental.

### 1. A per-call heartbeat in `DangerClaudeRunner`

`danger_claude_prompt` and `danger_claude_commit` (both in
`lib/autodev/danger_claude_runner.rb`) are the only two methods that spawn
danger-claude for issue-scoped work — every issue-scoped call goes through one
of them, and both reach `run_with_timeout('danger-claude', …)`, which owns the
`dc_timeout` kill. A private helper emits one activity row at the **start** of
each:

Two danger-claude call sites bypass `DangerClaudeRunner` entirely and are
**not** covered by this guarantee: `Autospec::ProjectBriefer#invoke_danger_claude!`
(`app/services/autospec/project_briefer.rb`, raw `Open3.capture3`, no timeout)
and `Autodev::UsageChecker#send_probe` (`lib/autodev/usage_checker.rb`). Neither
is issue-scoped today, so nothing is broken — but a future issue-scoped call
written in `ProjectBriefer`'s style would silently fall outside the invariant.
"Every danger-claude call in the codebase funnels through here" was the
original, broader claim; it does not hold once these two are counted, so the
guarantee is stated as issue-scoped only.

```ruby
# lib/autodev/danger_claude_runner.rb
#
# The invariant the dormant audit rests on (Autodev #50): a live worker's
# silence must stay under HealthReport#stuck_active_after, or
# dispatch_dormant_audit can reposition a row while an IssueProcessJob holds
# the concurrency lock on it. Per-state business events do not guarantee that —
# PipelineFixer makes 2 calls per failed job and emits nothing per iteration —
# so liveness is recorded per call, here, where every call funnels.
#
# Before the call, not after: the clock resets when the call starts, so the
# longest gap is one call's timeout plus loop overhead, whatever the loop does.
def dc_heartbeat!(label)
  ActivityLogger.heartbeat!(@dc_issue, label)
end
```

`ActivityLogger.heartbeat!` writes DB-only — no GitLab round-trip, so the cost
is one INSERT and the issue thread stays unchanged:

```ruby
# lib/autodev/activity_logger.rb
# Liveness marker for the dormant audit (Autodev #50). DB only, and no i18n
# entry: this row is never rendered — `without_activity_since` is its only
# reader. No-op without a tracked issue, same contract as log_activity_warn.
def self.heartbeat!(issue, label)
  return unless issue

  ActivityEvent.create(issue_id: issue.id, kind: 'heartbeat', level: 'info',
                       payload_json: JSON.generate(event: 'dc_call', label: label))
rescue StandardError
  nil
end
```

`'heartbeat'` joins `ActivityEvent::KINDS`.

**Invisible to the UI, through one definition rather than three filters.** A
scope on the model is the single place that says "this kind is machinery":

```ruby
# app/models/activity_event.rb
# Rows that exist for the dormant audit's staleness query only (Autodev #50).
# `without_activity_since` counts every row on purpose — that is what bounds a
# live worker's silence — so the exclusion belongs to the readers that render.
scope :user_visible, -> { where.not(kind: 'heartbeat') }
```

Three consumers change:

| Site | Change |
|---|---|
| `IssuesController#events_for` | `activity_events_dataset.user_visible.where(issue_id: …)` |
| `Web::Helpers#weekly_activity_counts` | already excludes `poller` / `error`; add `heartbeat` |
| `ActivityEvent#broadcast_to_event_bus` | `return if issue_id.nil? || kind == 'heartbeat'` (the row carries an `issue_id`, so the existing guard would let it through to `/stream`) |

`Issue.without_activity_since` is deliberately **not** filtered: counting the
heartbeat is the whole mechanism.

### 2. `stuck_active_after` derived from the longest configured timeout

```ruby
# app/services/autodev/health_report.rb
# Heuristic, not a bound, for as long as any inter-call work is untimed: the
# worst-case gap for a live worker is (heartbeat -> call end: <= dc_timeout +
# kill grace + pipe drain) + (call end -> next heartbeat or transition: untimed
# inter-call work — screenshot uploads, job_trace fetches, git operations, the
# clone_and_checkout inside post_completion). The factor pays for the second
# term; it multiplies a timeout, not a heartbeat interval, hence the name.
TIMEOUT_SLACK_FACTOR = 2

def stuck_active_after
  @stuck_active_after ||= [configured_stuck_active_after,
                           TIMEOUT_SLACK_FACTOR * longest_worker_timeout].max
end
```

- `configured_stuck_active_after` = `monitoring.stuck_active_after_seconds` or
  `STUCK_ACTIVE_AFTER` (7200), unchanged.
- `longest_worker_timeout` = the maximum of:
  - `Config::DEFAULTS['dc_timeout']` and
    `PipelineMonitor::PostCompletion::DEFAULT_TIMEOUT` — the effective values for
    a project that overrides neither, so they are always in the max;
  - `Project.maximum(:dc_timeout)` and `Project.maximum(:post_completion_timeout)`
    — the DB overrides (`nil` when there are no rows, dropped from the max);
  - the same two keys on each `@config['projects']` YAML entry, for a project
    configured but not yet imported into the `projects` table.

`post_completion_timeout` is in the max because `running_post_completion` ∈
`REVIVE_TO_DONE` and its shell command gets **no** heartbeat — it is not a
danger-claude call — so its silence equals its timeout exactly. The `|| 300`
literal in `lib/autodev/pipeline_monitor/post_completion.rb:25` becomes
`Config::POST_COMPLETION_TIMEOUT`, read by both sites, so the two cannot drift.
It lands on `Config` rather than on `PostCompletion` because `test/rails_helper.rb`
boots Rails without `lib/autodev`'s tree (it requires only `locales`, `config`
and `gitlab_helpers`): a constant on `PipelineMonitor` would `NameError` the
moment `HealthReport` is exercised from `test/services/`.

**`reviewing` was an acknowledged exception; Autodev #54 closed it.** `mr-review`
is an LLM review of the full MR diff, and at the time of this design it ran via
`Open3.capture3` with **no timeout**, at two call sites
(`PipelineMonitor::Reviewer#run_mr_review_command`,
`IssueProcessor::MrManager#execute_review` — the latter since found to be dead
code and deleted). Not being a danger-claude call, it contributed **no term** to
`longest_worker_timeout`: unlike `running_post_completion` there was no configured
timeout to fold into the max. Both sites got `dc_heartbeat!('mr-review')`
immediately before the call, which bounded silence in `reviewing` at one mr-review
run plus the 15 s pre-sleep rather than leaving it unbounded — but it did not
close the exposure, because nothing sized the window for a run that never
returned. #54 routes the call through `run_with_timeout`, capping it at a new
per-project `mr_review_timeout` (baked default `Config::MR_REVIEW_TIMEOUT` =
3600 s) — a term `HealthReport#longest_worker_timeout` **gained**, rather than an
existing one it reused — so `reviewing` is now covered like any other state and
`running_post_completion` is the only remaining exception. See
`2026-08-10-mr-review-timeout-design.md`.

Consequences:

- **No behaviour change at the default configuration**: `2 × 1800 = 3600 <
  7200`, so the floor still wins and the card keeps flagging exactly what it
  flags today.
- An explicit `monitoring.stuck_active_after_seconds` is a **floor, not a
  ceiling**: a wider value wins, a narrower one loses to the derived value. That
  is the point — the operator can no longer configure an incoherent pair. The
  effective value is surfaced as `meta[:window_seconds]` on the `stuck_issues`
  check so it is visible rather than implicit.
- `DormantAudit#active_window` already delegates here, so both readers move
  together by construction. No cross-field validation to write, and no second
  setting to keep consistent — which is why this is preferred over a
  `ConfigValidator` rule.

### Rejected: moving the active arm behind the job lock

Enqueuing an `IssueProcessJob(:audit_dormant)` instead of mutating inline would
remove the timing coupling outright, and is the principled fix. It is not worth
it here: it reworks a pass shipped in `1.0.0-alpha.46`, splits the three arms
into inline and deferred paths, and buys nothing once a live worker's silence is
bounded by construction. Recorded as the fallback if the heartbeat ever proves
insufficient.

## Testing

TDD, one test per claim.

**Heartbeat** (`test/danger_claude_runner_heartbeat_test.rb`)
- `danger_claude_prompt` writes exactly one `kind: 'heartbeat'` row, carrying the
  call label.
- `danger_claude_commit` does the same — both entry points, so a future caller of
  either is covered.
- No GitLab client call is made (the fake client fails the test if touched).
- No row and no raise when `@dc_issue` is nil.

**Invisibility** (`test/activity_event_heartbeat_test.rb`, beside `activity_event_test.rb`)
- A heartbeat row is not published to `Web::EventBus`.
- `Issue.without_activity_since` **does** see it (the load-bearing assertion),
  and an out-of-window heartbeat does not hide a genuinely stale row.
- `weekly_activity_counts` ignores it (extends `test/weekly_activity_counts_test.rb`,
  whose `Host` class already mixes in `Web::Helpers`).
- The issue timeline omits it, asserted through the rendered activity count
  (`web_issue_activity` → "Activity (%{count})") in
  `test/controllers/issues_controller_heartbeat_test.rb`.

**Derived window** (`test/services/health_report_stuck_window_test.rb`)
- Default config → 7200, unchanged.
- A DB project with `dc_timeout: 5400` → 10800.
- A DB project with `post_completion_timeout: 5400` → 10800.
- A YAML-only project (no `projects` row) is counted too.
- `monitoring.stuck_active_after_seconds: 20000` wins over a 3600 derived value.
- `monitoring.stuck_active_after_seconds: 3600` loses to a 10800 derived value.
- `check_stuck_issues` does not flag a row silent for 3 h when the window is 4 h,
  and reports `meta[:window_seconds]`.

**Dormant audit** (`test/dormant_audit_selection_test.rb`, extended)
- The active arm does not select a row silent for 3 h when a project's
  `dc_timeout` puts the window at 4 h — the regression the ticket asked for.

## Docs

- `CHANGELOG.md` `[Unreleased]`.
- `docs/observability.md` §`stuck_issues` — the window is now derived, and why.
- `docs/usage/autodev-technical-usage.md` — the "Issues bloquées" card's window.
- Cross-reference from `health_report.rb` and `dormant_audit.rb` comments to this
  file, and from `2026-08-07-dormant-rows-audit-design.md` §4 (which states the
  active arm's window as a flat 7200).

## Constraints

CLAUDE.md: TDD, RuboCop green (`mise x ruby -- rubocop`, never edit
`.rubocop.yml`), Conventional Commits, `CHANGELOG.md` `[Unreleased]` updated in
the same pass, every user-facing string through `Locales.t` / `t_web` in both
`fr` and `en` (this change adds none — the heartbeat is never rendered).

## Out of scope

- Rendering the heartbeat in the UI. It would give operators live progress during
  a 30-minute run, but it changes the issue timeline's meaning and deserves its
  own decision; the scope keeps it to one line (`user_visible` plus a `kind`
  i18n label).
- Moving `DormantAudit`'s active arm behind the Solid Queue lock (see Rejected).
- The `whiny_transitions: false` silence itself. A no-op transition under a
  repositioned row logs nothing; that is a broader design question than #50.

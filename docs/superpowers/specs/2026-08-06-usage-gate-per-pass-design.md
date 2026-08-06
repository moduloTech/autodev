# Per-pass Claude usage gate (Autodev #46)

Date: 2026-08-06
Ticket: Skynet Autodev #46 — "Le gate de quota Claude suspend aussi les passes de poll qui ne consomment rien"

## Problem

`AutodevPollJob` is gated on `UsageChecker#available?`. When the Claude quota is
exhausted the job returns before running a single dispatch pass:

```
WARN  -- : Claude usage exhausted, skipping poll cycle
INFO  -- : [autodev_poll] usage limit hit, skipping cycle
activity_events: {"event":"cycle_complete","usage_ok":false,"projects":0}
```

The gate is correct for anything that shells out to `danger-claude` or
`mr-review`. It is wrong for the observation-only passes, which cost no Claude
credit at all:

- `dispatch_unassignment` — unassignment **and** GitLab closure detection (#44).
  A ticket closed on GitLab keeps showing as in-progress for the whole outage.
- `dispatch_pipelines` — pipeline tracking. At the time of the report 21 MRs sat
  in `checking_pipeline`: a pipeline turning green is not seen, so no review and
  no delivery.
- `dispatch_done_unassigned` — the `post_completion` hook (a shell command).
- `dispatch_error_recheck` and the `:retry_errored` branch of `dispatch_retries`
  — these only re-arm budgets and fire transitions.
- `dispatch_infra_recheck` — regex pre-triage over the GitLab API.

A quota outage therefore does not merely pause implementation: it freezes every
already-implemented ticket whose remaining path depends only on GitLab.

## Design

### 1. `Autodev::UsageGate` — shared quota state

New service at `app/services/autodev/usage_gate.rb` exposing two class methods:

- **`probe!(logger:)`** — runs `UsageChecker`, persists the verdict as an
  `ActivityEvent(issue_id: nil, kind: 'usage', level: available ? 'info' : 'warn',
  payload: { available:, checked_at: })`, returns the boolean. Called once per
  cycle by `AutodevPollJob`, *before* dispatching.
- **`available?`** — passive read of the most recent `kind: 'usage'` event.
  **Fail-open**: no event, unparseable payload, or an event older than the TTL
  yields `true`. TTL = `max(2 × poll_interval, 600s)`.

`'usage'` joins `ActivityEvent::KINDS`. No migration is needed: `issue_id` is
already nullable and `payload_json` already exists. `broadcast_to_event_bus`
already skips events without an `issue_id`, so the SSE feed stays clean.

Fail-open mirrors today's `usage_paused?` rescue: a failure to observe the quota
must never be what stops the pipeline.

Reading a persisted verdict — rather than probing per worker — matters because
`UsageChecker` shells out to `danger-claude`. It is instantiated per call, so its
TTL cache never spans two jobs; probing at each consumption point would mean up
to N probes per cycle.

### 2. Push the gate below `AutodevPollJob`

`AutodevPollJob` no longer returns early. It probes once, then passes
`usage_ok:` to every `PollDispatcher`.

| Pass | Quota exhausted |
|---|---|
| `dispatch_new_issues` (`:process`) | **skipped** |
| `dispatch_discussions` (`:fix_discussions`) | **skipped** |
| `dispatch_retries` → `:retry_stuck` | **skipped** |
| `dispatch_retries` → `:retry_errored` | runs (transitions + labels only) |
| `dispatch_pipelines` (`:check_pipeline`) | runs |
| `dispatch_unassignment` (incl. GitLab closure) | runs |
| `dispatch_done_unassigned` (`:post_completion`) | runs (shell command) |
| `dispatch_error_recheck` | runs (re-arms budgets) |
| `dispatch_infra_recheck` (`:recheck_infra`) | runs (regex pre-triage + GitLab API) |

The heartbeat keeps its `usage_ok` field and now carries the real project count
instead of `0`.

### 3. Gate at the switching point inside `PipelineMonitor`

`:check_pipeline` keeps running during an outage, but two of its branches reach
Claude. Both are gated on `UsageGate.available?`, read at execution time:

- **`handle_green` with `review_count == 0`** → `mr-review`. When the quota is
  out: no transition, no counter touched, the ticket stays in
  `checking_pipeline`, one log line. The gate sits *before*
  `log_activity(:pipeline_green)` so the GitLab activity note is not rewritten
  every cycle for the whole outage.
- **`triage_and_fix` → `check_stagnation_and_fix`** (Claude evaluation + fix).
  When the quota is out: return *before* `update_stagnation_signature`, so a
  paused cycle cannot burn the stagnation budget. `retrigger_if_needed` and
  `infra_skip?` run earlier in the chain and are unaffected — neither calls
  Claude.

`recheck_infra_recovery` and the post-completion sequence were audited and reach
no Claude entry point, so they need no gate.

### 4. Defensive gate in `IssueProcessJob`

A job enqueued just before the quota ran out can still start Claude. For
`:process`, `:fix_discussions` and `:retry_stuck`, check `UsageGate.available?`
on entry; when false, log and return. Each of those actions leaves the row in a
state the next cycle rediscovers (`pending` / `fixing_discussions` /
`pending` + `next_retry_at`), so nothing is lost.

### 5. Visibility

- **Dashboard** — a warn banner for every signed-in user (not admin-gated: the
  outage affects everyone's tickets), same visual treatment as the existing
  "Anthropic not configured" banner, carrying the last probe time. Copy states
  that implementation is paused while pipeline tracking and closure detection
  keep running. i18n keys `web_dashboard_usage_paused_title` / `_hint` in both
  `fr` and `en`.
- **`HealthReport#check_claude_usage`** — switches from the last poller
  heartbeat to the `UsageGate` state, which is written at probe time rather than
  at cycle end. Same envelope; `/healthz` is unchanged.

### 6. Work accumulation (ticket point 2)

No throttle is added. During an outage the pipeline pass keeps moving tickets to
`done` or `fixing_discussions`. `dispatch_discussions` already re-enqueues those
rows on *every* cycle in normal operation, so recovery is not a new burst
shape, and `queue.yml`'s `threads` setting (`AUTODEV_MAX_WORKERS`, default 3)
already serializes execution. Adding a queue-drain limiter would duplicate a cap
that exists.

## Testing

Written test-first:

- `test/services/autodev/usage_gate_test.rb` — probe writes the event; `available?`
  reads the latest one; fail-open on missing, unparseable and stale state.
- `test/services/autodev/poll_dispatcher_test.rb` — the section-2 matrix: with
  `usage_ok: false`, no `:process` / `:fix_discussions` / `:retry_stuck` is
  enqueued, while `:check_pipeline`, closure detection, `:post_completion`,
  `:retry_errored` and `:recheck_infra` still happen.
- `test/jobs/autodev_poll_job_test.rb` — the cycle runs with the quota out; the
  heartbeat carries `usage_ok: false` and the real project count.
- `PipelineMonitor` tests — green + `review_count == 0` with the quota out stays
  in `checking_pipeline` with no `review_count` increment and no activity note;
  red + code verdict with the quota out leaves the stagnation signature alone.
- `test/jobs/issue_process_job_test.rb` — the three consuming actions no-op when
  the quota is out.
- `test/services/health_report_test.rb` — `claude_usage` reads the gate state.
- Dashboard view test — banner rendered when paused, absent otherwise.

## Constraints

TDD, RuboCop green (`mise x ruby -- rubocop`), `CHANGELOG.md` `[Unreleased]`
updated in the same pass, Conventional Commits.

# Plan — a duplicate `:process` job does nothing (Autodev #140)

Spec: `docs/superpowers/specs/2026-10-21-a-duplicate-process-job-does-nothing-design.md`.
One lane (three production lines and their tests); no parallel dispatch.

## Contract

- `IssueProcessJob::DISPATCHED_FROM[:process] == %w[pending]` (frozen literal).
- `Issue::PROCESSABLE_STATES` unchanged (`%w[pending needs_clarification]`), read by
  `PollRouter#route_by_state` only.
- `IssueProcessor#start_processing(issue)` returns truthy when `issue.start_processing!`
  happened, `false` otherwise, and writes nothing in the false case; `#process` returns
  right after a false.

## Steps (TDD)

1. New `test/a_duplicate_process_job_does_nothing_test.rb` (DatabaseTestHelper, real
   `Issue` row, real `IssueProcessJob`, real `IssueProcessor`, a recording GitLab client):
   - two `:process` jobs: the first, with the processor's pipeline replaced by the real
     `spec_unclear!` path ending in `needs_clarification`, the second running against the
     parked row → no client call at all, no clone (`clone_and_prepare` never called), no
     `ActivityLogger.post`, row unchanged (`status`, `started_at`).
   - processor alone on a `needs_clarification` row (the job guard bypassed) → same
     assertions: no client call, no clone, no activity, `started_at` nil.
   - control: processor on a `pending` row reaches `clone_and_prepare` and `apply_label_doing`.
2. `test/jobs/issue_process_job_test.rb`: `:process` does not reach its body from
   `needs_clarification` (the existing ACTION_STATUS converse already covers `pending`).
3. `test/clarification_is_reachable_test.rb`: replace "the router and the job agree" with
   (a) the job's `:process` states are a subset of the router's, (b) the router still lets
   `needs_clarification` through, (c) every `:process` enqueue site in `app/` + `lib/` is
   declared with how it makes the row `pending` (source scan, idiom of
   `test/api_failure_is_not_a_verdict_test.rb`), and (d) behaviour: an answered
   `needs_clarification` row through `process_issue` and through `ClarificationSweep#apply!`
   yields a job that passes the guard.
4. `test/a_duplicate_job_finds_nothing_to_do_test.rb`: correct the `:process` sentence.
5. Implement: the constant, `start_processing` / `process`.
6. Comments: `Issue::PROCESSABLE_STATES`, `DISPATCHED_FROM`, `ClarificationSweep#apply!`,
   `PollDispatcher#clarification_received?` where they claim the job reads the constant.
7. CHANGELOG `[Unreleased]`, CLAUDE.md sentence on `PROCESSABLE_STATES`.

## Verification

Full suite (`RAILS_ENV=test mise x ruby@4.0.1 -- bin/rails test`), each touched test file
alone, `mise x ruby@4.0.1 -- bin/rubocop`.

## What the plan adversary added (`ship-plan-adversary`, 21/10/2026)

| Would stay green | Test assigned |
|---|---|
| The duplicate-job test held by the processor's refusal alone, with the job guard reverted | the second run builds no processor (`IssueProcessor.new` flunks) |
| A refusal that writes `activity_events` directly | the snapshot counts `ActivityEvent` rows; `ActivityLogger.post` flunks in the processor test |
| The refusal's log line | asserted on a `StubLogger` |
| A `StaleTransitionError` swallowed inside `start_processing` | a row closed under the processor: nothing written, nothing called |
| A refusal keyed on `started_at` / clarification history | a resumed row (`started_at` set) is processed again through the job |
| The two inline callers refused | `:retry_stuck` through the job, and `reenter!` then `process`, both reach the clone |
| The `SELF_CLEARING` sentence for `:process` | derived: no state reachable from `cloning` (AASM graph), `pending` excepted, is in `DISPATCHED_FROM[:process]` |
| `test/clarification_reposes_the_entry_label_test.rb` encoded the defect (row left in `cloning`) | fixture fixed with `clone_complete!`, asserts the row is `cloning` |

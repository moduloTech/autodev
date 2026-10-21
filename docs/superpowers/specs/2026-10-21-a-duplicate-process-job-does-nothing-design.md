# A duplicate `:process` job does nothing (Autodev #140)

## What happened

Measured by the ticket in production on 15/10/2026 (A#164, powerpanne/core#16627 —
journal and `activity_events`, Paris time; not re-measured here: production was not
reachable from this machine on 21/10/2026, NetBird `NeedsLogin`):

- 05:10 → 05:20: six `IssueProcessJob(:process)` enqueued for the same row while it was
  `pending`. The queue was late (Autodev #139), so none started before 05:27.
- 05:27, job 1: the normal run — spec check, 3 questions, `checking_spec →
  needs_clarification` (the only transition in the database), entry label reposed.
- 05:28:05 and 05:28:51, jobs 2 and 3: no transition, but `apply_label_doing`, a clone, a
  spec check, a new set of questions posted, entry label reposed again.
- 05:38, jobs 4 to 6: `label_doing` posed, clone, spec check, then the Claude quota ran out;
  `mark_failed` is refused from `needs_clarification` (Autodev #128: nothing written,
  nothing posted), so nobody reposed the entry label. The ticket stayed on
  `Development::Doing`, out of `dispatch_new_issues`' population: an answer would never
  have been read. `ClarificationWatch` flagged it `clarification_label_moved` at 10:00.

The requester received three different sets of questions (3, 5, 5) in two minutes.

## Cause

`IssueProcessJob::DISPATCHED_FROM[:process]` was `Issue::PROCESSABLE_STATES`
(`pending` + `needs_clarification`). Autodev #75 shared that one constant between the
router and the job so the two could not disagree. But the job's guard answers a different
question from the router's: the router asks "may this row enter `process_issue`", the guard
asks "is the work this job was queued for still to do" (Autodev #61). A `:process` run can
*end* in `needs_clarification`, so a duplicate queued behind it found the row in a state its
guard accepted. `IssueProcessor#start_processing` then fired `start_processing!`
(`from: :pending` only), which `whiny_transitions: false` turns into a silent `false`, and
ran `apply_label_doing`, `log_activity(:started)` and the whole pipeline regardless — the
Autodev #61 shape, reopened by #75.

`test/a_duplicate_job_finds_nothing_to_do_test.rb` declared `:process` self-clearing on the
sentence "leaves PROCESSABLE_STATES on start_processing!". It was false from #75 on: a run
leaves the set on `start_processing!` and can come back into it on `spec_unclear!`.

## Every `:process` enqueue moves the row to `pending` first

Checked by reading every enqueue site in `app/`, `lib/` and `bin/` on 82cf6b1:

| Site | How the row is `pending` when the job is enqueued |
|---|---|
| `PollDispatcher#process_issue` (`app/services/autodev/poll_dispatcher.rb`) | a new row is created `pending` (`find_or_create_issue`); an existing row passes `skip_existing?` only when `pending`, or when `needs_clarification` **and** `clarification_received?` resumed it (`ClarificationResume#resume!` → `clarification_received!`) and it is now `pending?` — a resume onto `fixing_discussions` (Autodev #121) is skipped |
| `ClarificationSweep#apply!` (`app/services/autodev/clarification_sweep.rb`) | `resume!` first, then enqueues only `if issue.pending?` |

No other code enqueues `:process`: `ReviewArrearsSweep`, `DormantAudit`, the dashboard
controllers and the rake tasks enqueue other actions or none. Two non-job callers run
`IssueProcessor#process` inline, both from `pending`: `PollRouter#enqueue_issue_processing`
after `reenter!` (`done`/`closed → pending`), and `IssueProcessJob#perform_retry_stuck`
(dispatched from `pending`).

So a `:process` job that finds its row in `needs_clarification` is always a duplicate: the
poll had already moved the row to `pending` before enqueuing it, and something else moved
it back.

## Decision

1. **`DISPATCHED_FROM[:process]` is `%w[pending]`**, written literally like
   `retry_stuck`'s, and no longer `Issue::PROCESSABLE_STATES`. `PROCESSABLE_STATES` stays
   what `PollRouter#route_by_state` reads — the router must still let a waiting row reach
   `process_issue`, which is the only code asking whether the human answered (#75).
   The two lists are different on purpose now, and the #75 hazard ("the narrower of the two
   wins by dropping the row") is held by a different invariant: every `:process` enqueue
   site leaves the row `pending` (table above), which a test declares site by site and
   checks behaviourally for both sites.

2. **Defence in depth: `IssueProcessor#process` stops when `start_processing!` did not
   happen**, before any write — no `started_at`, no `label_doing`, no `:started` activity
   entry, no ticket read, no assignment, no `:processing_started` note, no clone. One log
   line says which state the row was in. This covers a caller that reaches the processor
   without the job's guard (the two inline callers above) and any state the guard may
   accept in future. A `StaleTransitionError` out of `start_processing!` (the row changed
   under the job, Autodev #97) keeps its existing route through `handle_process_error`.

3. `test/a_duplicate_job_finds_nothing_to_do_test.rb`'s `:process` sentence is corrected.

## Assumptions

- A row in `needs_clarification` is never legitimately the start state of a `:process`
  run. Holds because `clarification_received!` is the only way out of that state towards
  `pending`, and both enqueue sites fire it before enqueuing.
- The refusal is logged and nothing else: no `activity_events` row, no GitLab write. Same
  as `log_stale_skip`, which is the job-level twin of this refusal.

## Owner may reverse

- **What the processor's refusal records.** Chosen: one log line, nothing on the ticket,
  no `activity_events` row. Alternatives: (a) an `activity_events` row of a machinery kind
  — visible on `/issues/:id`, but on A#164 it would have added five rows for five
  duplicates, and it adds a kind to `MACHINERY_KINDS`; (b) a GitLab note — would have told
  the requester five more times that something happened on the ticket, the exact noise this
  ticket removes. With the job guard narrowed, the processor's refusal is unreachable from
  the job on the motivating case; it only fires for the inline callers.

## Out of scope

- The queue being late (Autodev #139, same lot): it made six duplicates possible, but a
  duplicate must be harmless whatever the queue's delay.
- PowerPanne #16627's remediation (label, message to the requester): done by the owner.

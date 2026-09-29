# A pipeline failure lands in `error`, and a refused failure writes nothing (Autodev #128)

## The defect

`PipelineMonitor::FailureHandler#attempt_fix` rescues every `StandardError` into
`handle_failure_error`, which calls `safe_mark_failed!` and then
`persist_and_notify_failure` (writes `error_message`, posts the public
`pipeline_fix_error` comment, logs an `:error` activity entry).

Part of the rescued work runs **before** `issue.pipeline_failed_code!`
(`PipelineFixer#dispatch_fix`), while the row is still `checking_pipeline`: the
clone, the rebase, the job-log writing, the Claude evaluation, the prompt-context
read. `mark_failed` has no transition from `checking_pipeline`
(`app/models/issue.rb:163`), `Issue` runs with `whiny_transitions: false`, so
`mark_failed!` returns `false` and raises nothing, and the
`rescue AASM::InvalidTransition` fallback in `safe_mark_failed!`
(`lib/autodev/danger_claude_runner.rb:185`) never fires. The row stays
`checking_pipeline` with an `error_message` and a public failure comment;
`dispatch_pipelines` re-enqueues it next poll, the same error recurs, the comment
is posted again.

### Measured

- A#105 (POWERPANNE#15819), 09/06/2026, dev copy of production:
  5 `activity_events` of key `error` (`Encoding::UndefinedConversionError`) at
  08:36, 08:38, 08:40, 08:42, 08:44 UTC, one per poll, each preceded by
  `pipeline_red`; no transition out of `checking_pipeline`. A#106 (15820) the same
  day, same pattern.
- The sixth poll (08:45) ended on `stagnation_pipeline`. That bound no longer
  exists: since Autodev #71 (8850b44, 17/08/2026) the stagnation signature is
  written **after** `clone_and_fix` returns, and a raise skips the write. On
  today's code the only bound left is the watch's age: `abandon_expired_watch`
  still gives up after `pipeline_watch_max_days` (14), since the refused
  transition left `checking_pipeline_since` untouched — up to ~10 000 public
  comments at production's 120 s cycle. `DormantAudit` never sees the row (it
  is active and produces activity every poll). (Corrected on adversarial
  review: the first draft said "unbounded".)
- The comment above `check_stagnation_and_fix` already claims that a
  `RateLimitError` or `StandardError` from the fix "park the row in `error` with
  `next_retry_at`". From `checking_pipeline` that claim was false.

### Census of `safe_mark_failed!` callers and the states they reach

| Caller | Reachable in-memory states | Outside `mark_failed`'s sources |
|---|---|---|
| `PipelineMonitor::ErrorHandler` (`handle_rate_limit`, `handle_auth_failure`, `handle_failure_error`) via `attempt_fix` | `checking_pipeline` (everything before `pipeline_failed_code!`), `fixing_pipeline` | **`checking_pipeline`** |
| same, via `Reviewer#handle_review_interruption` | `reviewing` | — |
| `MrFixer::ErrorHandler` | `fixing_discussions` | — |
| `IssueProcessor::ErrorHandler` | `cloning` … `creating_mr`, `answering_question`, **`needs_clarification`** after `spec_unclear!` (`spec_checker.rb:113`) if a later write raises, and **`checking_pipeline`** after `mr_created!` (`issue_processor.rb:109`) if `persist_finalize` / `log_activity` / `notify_localized` raises (found on adversarial review) | **`needs_clarification`**, **`checking_pipeline`** |

## Decision (owner, 29/09/2026)

1. **`checking_pipeline` becomes a source of `mark_failed`.** It is the state the
   pipeline worker works from; `error → checking_pipeline` (`retry_pipeline`)
   already exists as the way back. The transition goes through
   `after_all_transitions`, so the #97 guard (`refuse_stale_transition!`) holds,
   a `transition` activity row is written, and `checking_pipeline_since` is
   cleared by `stamp_pipeline_watch!`.
2. **A refused `mark_failed` writes nothing and posts nothing.**
   `safe_mark_failed!` tests the return value of `mark_failed!` and returns it.
   On `false` it discards the in-memory `next_retry_at` assignment, logs the
   refusal (state and caller-visible reason), and every caller returns before its
   writes (`error_message`, `dc_stdout`/`dc_stderr`, `retry_count`,
   `finished_at`, comment, activity entry). The dead
   `rescue AASM::InvalidTransition → update(status: 'error')` is removed: it
   could not fire, and had it fired it would have written `error` over a state
   the database no longer held, bypassing #97.

   This departs from the ticket's second "À PROUVER" item ("from a state without
   a transition, the row ends in `error`"): forcing `error` from
   `needs_clarification` would tell a requester whose questions were just posted
   that their ticket failed — the outcome Autodev #75 already chose against —
   and forcing it from `done`/`closed` would overwrite a concluded or human
   decision. The owner chose "write nothing" over "force `error`".

## What the loop becomes

Poll 1: `checking_pipeline → error`, `next_retry_at` NULL, one comment. The
`DormantAudit` error arm revives it after `pending_window` (`retry_count: 0`,
`next_retry_at: now`), `perform_retry_errored` → `retry_pipeline!` →
`checking_pipeline`; if the failure recurs, one more comment per revival, up to
`dormant_audit_max` (3) → `needs_attention` (`dormant_exhausted`). One comment
per real attempt, at least `pending_window` apart (15 min in production:
`max(3 × 120 s, 900 s)`), three at most — instead of one per poll for up to
14 days.

**The revival budget is per row, not per incident** (adversarial review).
`dormant_recheck_count` is only ever incremented (`DormantAudit#audit`), so the
three revivals are shared across the row's whole life and with the pending and
active arms; a fourth unrelated pre-fix failure, weeks later, flags the row
`dormant_exhausted` (an operator signal, no GitLab comment) instead of reviving
it. This is not new in kind — `MrFixer#handle_fix_error` has always sent rows
down the same path — and Autodev #125 resets the budget on a human resume. See
the owner decision recorded below.

A `RateLimitError` from the evaluation now also parks the row in `error` with
`next_retry_at` = the reset time, as it already did from every other state.

A human close during a fix from `checking_pipeline` now raises
`StaleTransitionError` in `safe_mark_failed!` (the transition is legal from the
in-memory state, the row no longer holds it), which `check` answers with
`stop_on_stale_transition` — no `error_message`, no comment. Before, the refusal
was silent and the comment went out on a closed ticket.

### Other consequences of the new source

- `IssueProcessor` after `mr_created!`: a raise there used to leave the row on
  the watch with `retry_count` incremented, a backoff stamp and an error
  comment; it now lands in `error` with that backoff and is retried through
  `retry_pipeline!`. Pinned by a test.
- The dashboard's transition menu (`permitted_events_for`) now offers the
  manual `mark_failed` on a `checking_pipeline` row, as it already did on every
  other active state. Fired without a stamp, the row is revived by the dormant
  audit like any other stampless `error`.

## Out of scope

- The #125 control test `test_control_a_local_system_call_error_is_still_a_fix_failure`
  lives on `fix/125-…`, not on master; its `status == 'error'` assertion is
  added when the alpha-56 lot is integrated.
- Whether a pipeline-fix failure should schedule its own retry (the asymmetry
  with `IssueProcessor`'s backoff) stays the open policy question #103 left.
- Why the June `Encoding::UndefinedConversionError` happened.

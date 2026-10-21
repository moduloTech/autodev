# Progress returns the dormant budget — design (Autodev #129, #135)

Two tickets, one definition. #129: `dormant_recheck_count` is spent over the
whole life of a row, so three unrelated, resolved incidents weeks apart exhaust
`dormant_audit_max` and the fourth flags `dormant_exhausted` instead of reviving.
#135: a row flagged `dormant_exhausted` that later restarts on its own keeps the
flag, and the dashboard shows as given up a request that pushed corrections this
week. Both ask the same question — *when has a row progressed?* — so they ship
together with one answer (owner).

## Measurements

- Production could not be read from this session (NetBird `NeedsLogin`,
  2026-10-21). The figures below are the batch's, measured read-only on
  production on 2026-10-16, and the tickets' own.
- `dormant_exhausted` on 11 rows: `checking_pipeline` 2, `fixing_discussions` 2,
  `error` 6, `done` 1 (#135 counted 11 active on 01/10, 8 on 08/10).
- `dormant_recheck_count`: 0 → 136, 1 → 6, 2 → 2, 3 → 17.
- #129's probe (adversarial review of #128): 4 incidents 10 days apart, each a
  failed poll, the audit, the retry and a healthy poll, end in
  `status=error dormant=3 attn=dormant_exhausted`.
- The development copy `~/.autodev/autodev.db` dates from 2026-08-12, before
  `dormant_exhausted` was ever written (no row carries it, 141 rows at count 0):
  it cannot answer anything here and was not used.

## The mechanism today

- One writer bumps the budget: `DormantAudit#audit` (`dormant_audit.rb`), via
  `issue.update`, no AASM event. One writer sets the flag: `DormantAudit#exhaust!`.
- Given back only by human gestures: the label resume (`ResumeHandler`,
  `DORMANT_BUDGET_RESET`, #125), the operator Reset (`reset_for_retry!(reset_budget: true)`),
  the manual re-entry (`Issue#clear_manual_reentry!`). The flag is cleared by
  the same gestures plus `ClarificationResume`, `ExternalState#close_row!` and the
  dashboard close.
- Every automatic way back — `retry_processing` / `retry_pipeline`
  (`perform_retry_errored`), `revive_stalled!`, `recover_errored!`, the audit's
  own revive, the quota-pause retry — leaves both alone.

## Decision

**A row progresses when it completes a unit of work.** The transition is decided
in one place, an `after_all_transitions` callback on `Issue`
(`return_dormant_budget_on_progress!`), so every caller of these events counts —
the workers, and an operator forcing one from the dashboard's transition menu —
and no other path does:

| Event | Counts | Why |
|---|---|---|
| `mr_created` | yes | the MR exists (owner: "MR creation") |
| `discussions_fixed` | yes | a discussion round completed (owner). Bounded on its own by `discussion_fix_round` / `stagnation_discussions`. One caller fires it without moving a counter: `MrFixer#transition_no_discussions`, a pass that found no thread left. It counts too — the step is over, and the next poll reads the same thread list (`MrDiscussions`) and delivers rather than sending the row back into an empty round |
| `pipeline_fix_done` | yes | a pipeline correction completed — the symmetric of `discussions_fixed`, and the success of the very path #128 sent to `error`. Bounded on its own by `stagnation_pipeline` — **owner may reverse** |
| `pipeline_green` → `done`, `mr_closed` (merged), `question_answered` | yes | a delivery (owner: "delivery (done)") |
| `pipeline_green` → `reviewing` / `fixing_discussions` | **no** | see below — **owner may reverse** |
| `review_done` | no | also fired by `resume_watch` on `:tool_unavailable` / `:inconclusive` / `:clone_failed`, i.e. a review that did nothing |
| `abandon`, `review_giveup`, `clone_complete` → `done` | no | a give-up or a closed ticket is not a delivery |
| `retry_processing`, `retry_pipeline`, and the `update_all` revivals | no | the revival itself: counting it removes the bound (owner) |
| every other event (`start_processing`, `spec_clear`, …, `reenter*`, `close`, `mark_failed`) | no | entering a step is not completing it; re-entries are handled by their callers (#125) |

At such a transition:

1. `dormant_recheck_count` → 0 and `dormant_recheck_at` → nil, for all three arms
   (the counter is shared by the arms, so one reset serves them all).
2. If the row **in the database** carries `attention_reason = 'dormant_exhausted'`,
   `needs_attention`, `attention_reason`, `attention_detail` are cleared.

Both are written by the transition's own `save!` (`persist_status_change!`), so a
transition refused as stale (Autodev #97) writes neither.

### Why `pipeline_green` counts only when it delivers

The owner listed `pipeline_green`. Taken whole, it removes the bound the owner
also required ("the same failure relaunched without progress still exhausts the
budget"): a worker that dies in `reviewing` or `fixing_discussions` is revived by
the active arm to `checking_pipeline` (`REVIVE_TO_PIPELINE`), whose next poll
reads **the same green pipeline** and fires `pipeline_green` back into the step
that keeps dying. Nothing else bounds that loop — `review_count` moves only on a
successful review, `discussion_fix_round` only on a completed round, and
`revive_stalled!` clears `checking_pipeline_since` so the watch age restarts on
each revive. With the whole event counted, the dormant budget would return on
every lap and the loop would never end. Re-reading a pipeline already green is
not progress; completing the step it leads to is, and both of those steps have a
completion event that counts (`discussions_fixed`) or a delivery that does.

### Reading the flag from the database

The worker holding the row may have loaded it before `DormantAudit#exhaust!`
flagged it (`update_all`, another process), or before a human cleared it. The
callback asks the database for `attention_reason` (one `pick`, beside the one
`refuse_stale_transition!` already makes) rather than trusting the loaded object:
a flag set since the load is lifted, a flag cleared since the load is not written
back. The budget columns are marked changed whatever the object read (the
`clear_delivery_on_reentry!` idiom), so a count the audit bumped since the load
is still reset.

### Articulation with #125

The human gestures keep their own reset, unchanged; this adds the automatic one.
`ResumeHandler::DORMANT_BUDGET_RESET` now reads `Issue::DORMANT_BUDGET_RESET`,
one definition for both. Nothing is duplicated: the human gesture resets at the
gesture, progress resets at the completion.

### #135's "budget unchanged"

#135 asked to clear the flag without touching the budget. The owner's single
definition supersedes it: progress returns both. What still holds from #135's
proof: the automatic **retry** itself changes neither — the flag and the count
stay until the row completes something.

### #135 point 3 — other attention reasons

Every writer of `attention_reason` was read (`grep -rn attention_reason app lib`):

- `abandon_issue` and `give_up_reviewing` write their reasons on a row going to
  `done` (the infra pass and the review-arrears sweep only select on them). Such
  a row returns to work only through
  `ResumeHandler` (label resume, infra recheck, review-arrears sweep — all three
  clear the flag in `reenter_via_pipeline_check` / `reenter_via_reimplementation`),
  the manual re-entry (`clear_manual_reentry!`) or the dashboard Reset
  (`clear_attention: true`). None survives an automatic resume.
- `ClarificationWatch`'s four reasons sit on `needs_clarification` rows; the watch
  rewrites or clears them as the condition changes and `ClarificationResume`
  clears them on resume.
- `dormant_exhausted` is the only reason written on a row in an active or
  `error` state by a pass that does not own its clearing — which is #135.

The one path that resets without clearing is the CLI `--reset` / `Dashboard`
reset (`reset_for_retry!(scope, reset_budget: true)` with no `clear_attention:`).
It is a human gesture on rows in `error`, and a row there can carry
`dormant_exhausted`; it is now lifted at the row's next progress. No measured
case of another reason surviving an automatic resume, so only
`dormant_exhausted` changes.

### The rows flagged today

No data migration, no rake (owner). The 4 active rows lose the flag at their
next progress after deploy; the 6 in `error` keep it, which is accurate; the
`done` one keeps it until a human re-enters it.

## Owner may reverse

1. **`pipeline_green` to `reviewing` / `fixing_discussions` does not count.**
   Options: (a) only its `done` branch counts — chosen; (b) the whole event counts,
   as listed — the loop above is unbounded (proved by
   `test_a_step_that_keeps_dying_after_a_green_pipeline_still_exhausts`, which
   fails under (b)); (c) count it only on a pipeline id not seen at the last
   revival — needs a new column. On #135's rows: under (a) a flagged row in
   `checking_pipeline` loses the flag at its next `discussions_fixed` or delivery
   rather than at its next green poll — one round later.
2. **`pipeline_fix_done` counts**, not in the owner's list. Options: (a) counts —
   chosen; (b) does not. On #129's motivating case (#128's failures before
   `pipeline_failed_code!`), (b) leaves a row whose pipeline corrections succeed
   but never turn green exhausting the budget over four incidents; (a) does not.

## Not done

- No activity entry or GitLab note announces the reset: the `transition` row of
  the progress event is in the journal already, and the flag is the operator's,
  never the requester's (`exhaust!` posts nothing either).
- No change to `DormantAudit`, its cap, its backoff, or the human gestures.

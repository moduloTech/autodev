# The alpha-56 lot read against its integration reviews — plan

Six branches (#127, #128, #94/#114, #101, #126, #125) were reviewed one by one,
then merged into `integration/alpha56`. Three reviews of the merged lot
(neutral, adversarial, truthfulness) found defects that exist only because the
branches now coexist, or that no single-branch review could see. The migration
collision and the misfiled changelog are already fixed (`43c503d`, `a416131`).
This plan covers the rest.

No separate spec: every decision below amends a decision one of the six
branches' specs already made, and says which.

Baseline: `mise x ruby@4.0.1 -- bundle exec rake test` → 3061 runs, 0 failures.

## F1 — an erased handover names the person who took the ticket (#101 × #126)

**Defect.** `LabelHandover::ErasedScan#erased_done/#erased_move/#erased_doing`
build `Verdict.new(reason, label)` with no `actor_id`, so
`ExternalState#stop_on_handover` falls back to `issue.handback_target`: the
ticket goes to the author or the displaced assignee, and the note still says
"je vous ai réassigné le ticket". Reproduced by all three reviews (human 999
moves the label, ticket goes to author 555; the same gesture read before
autodev's erasing write goes to 999).

**Decision (amends #126 point 3, "the ticket goes to the decisive event's
author", to cover #101's stage 3).** Each erased verdict carries
`actor_of(event)` of the event that decided it:

- `erased_done` / `erased_move`: the last foreign event on the label, the one
  `standing_add?` already inspects;
- `erased_doing`: the `last` foreign removal it already holds.

The `Verdict` comment "nil on a mere suspicion" becomes true again: after this,
every verdict `verdict` returns carries an actor; only `suspect`'s intermediate
suspicions do not.

**Tests.** In `test/a_handover_outlives_autodev_writes_test.rb`: for each of
the three reasons, the erased verdict's `actor_id` is the human's id, and
distinct from the author's (so a fallback to `handback_target` cannot pass);
and through `not_ours?`, the ticket is reassigned to the human, not the author.

## F2 — a manual re-entry from `done` starts a new delivery (#94 × dashboard)

**Defect.** The dashboard transition menu offers `reenter` and
`reenter_to_check_pipeline` from `done` (`IssuesController#transition`). Both
fire the AASM event alone: `POST_COMPLETION_CLEARED` is written only by
`reset_for_retry!` and by the two `ResumeHandler` reentries. The reservation of
the previous delivery survives, `dispatch_done_unassigned` never selects the
row again, and the page keeps the previous delivery's `post_completion_error`.
`Issue::POST_COMPLETION_CLEARED`'s comment ("what every writer that takes a row
back into work clears") is false.

**Decision (amends #94/#114).** The clear moves onto the two AASM events
themselves (an `after` callback), so every caller clears it, whichever path it
takes — label resume, `resume_recovered_infra`, `ReviewArrearsSweep`, the
dashboard. `reenter` (towards `pending`, a rebuild of the branch) also clears
`pending_resolutions`, as `reenter_via_reimplementation` already does
(#125 amendment 1: each entry says a correction is on the branch, and the branch
is rebuilt). `reenter_to_check_pipeline` keeps it: the MR and its branch stay.

A manual re-entry (`_audit_origin == :manual`) also stamps
`label_events_seen_until`, for the reason #101's adversarial review gave the
operator Reset: the human asking for the re-entry is the answer to "has anybody
taken this ticket". Without it, a reviewer's label move made while the row sat
in `done` — when autodev no longer held the ticket — would be read by
`ErasedScan` as a handover on autodev's first label write after the re-entry.
The automatic callers do not stamp: a recovery is not a statement about the
ticket (same rule as `reset_for_retry!`).

Out of scope, on purpose: the manual transition does not reset the budgets
(`retry_count`, …) the label resume resets. That is master's behaviour, not
this lot's, and changing it is a product decision.

The explicit `POST_COMPLETION_CLEARED` and `pending_resolutions: nil` in
`ResumeHandler` stay: they are in the same `update` as the other fields that
path resets, and removing them would make that update read as incomplete.

**Tests.** Firing `reenter!` and `reenter_to_check_pipeline!` on a `done` row
holding a reservation, an error and pending resolutions clears the first two on
both events and the third on `reenter` only; with `_audit_origin = :manual` the
floor is stamped, without it the floor is unchanged. Through the controller:
`POST /issues/:id/transition?event=reenter_to_check_pipeline` leaves the row
selectable by `dispatch_done_unassigned` once it is `done` again.

## F3 — `hand_ticket_back` claims only a handback GitLab honoured (#125 × #126)

**Defect.** `IssueNotifier#hand_ticket_back` answers `true` as soon as
`edit_issue` returns. GitLab Community answers 200 without honouring an
assignment in cases #126 established, so the abandon notice can claim a
reassignment that did not happen. Its siblings `ExternalState#hand_over_to`
and `CloseHandback` read the payload back with `GitlabHelpers.assigned_to?`.

**Decision.** `hand_ticket_back` reads the answer back the same way: `true`
only when the payload carries the target. The log line says which.

**Tests.** A client whose `edit_issue` returns a payload still carrying the bot
→ `false`; one carrying the target → `true`. Existing fakes whose `edit_issue`
returns `nil`/`true` and whose tests assert a claimed handback are updated to
return the payload.

## F4 — the `held_tickets` sample stays inside its card (#126)

**Defect.** At 1280 px the card's sample tokens
(`A#1(modulosource/powerpanne/powerpanne/core#15880,done)`, ~55 characters, no
break opportunity) overflow the card by ~59 px into the next one.

**Decision.** The meta spans of `/admin/health` wrap anywhere
(`overflow-wrap: anywhere`) and never exceed their card (`max-width: 100%`).

**Verification.** Geometry, not text: boot on a copy of the development
database, `getBoundingClientRect` of the sample and its card at 1280, 1024, 800
and 500 px; the sample's right edge ≤ the card's.

## F5 — the documents say what the merged code does

- `CLAUDE.md` #128 row and `CHANGELOG.md` #128 entry: the revival budget is
  "only ever incremented… shared across the row's whole life". Since #125 the
  label resume and the Reset give it back. New wording: never given back by an
  automatic path; only those two human gestures give it back.
- `CLAUDE.md` #125 row: "Deliberately not widened: … `LabelManager`". #126
  widened `LabelManager#manage_labels` to the transport family. The sentence
  keeps `notify_issue` and `assign_to_self`, and says `LabelManager` was widened
  by #126 and why that is safe there.
- `close_row!` hands nothing back — true on master, false since #126: in
  `erased_scan.rb`, the `CLAUDE.md` #101 decision and the #101 changelog entry,
  the sentence becomes historical ("before #126") and the gate's remaining
  justification (two contradictory comments) stays.
- `CHANGELOG.md` / `CLAUDE.md` #126: the actor sentence now holds for erased
  verdicts too (F1); the `POST_COMPLETION_CLEARED` sentence covers the AASM
  events (F2).
- `IssueNotifier#hand_ticket_back`'s merged comment is rewritten as one
  sentence, with no branch-relative wording.

## F6 — one transport family, checked

The six transport classes are spelled by hand at seven rescue sites
(`issue_notifier.rb` ×2, `mr_fixer.rb`, `label_manager.rb`,
`external_state.rb` ×2, `clarification_reach.rb`'s `READ_ERRORS`) because the
#62/#119 scanner matches literal class names. Today they all equal
`GitlabHelpers::TRANSPORT_ERRORS`; nothing keeps them so.

**Decision.** A test scans `app/` and `lib/` for every rescue clause or
`*_ERRORS = [...]` literal that names at least three of the six classes, and
asserts it names all six. `failure_handler.rb:103` is exempt by name: it splits
the family across two clauses on purpose (#125). The literals themselves stay.

**Test.** The scanner; sabotage by removing one class from one site.

## Order

F1, F3, F2 (TDD each), F6, F4 (with geometry), F5, then the full suite,
RuboCop, sabotage of every added test, three reviews.

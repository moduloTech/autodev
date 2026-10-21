# Progress returns the dormant budget — plan (Autodev #129, #135)

Spec: `docs/superpowers/specs/2026-10-21-progress-returns-the-dormant-budget-design.md`.

One lane: the change is one callback on `Issue` and one constant moved. Two
lanes would split a 30-line diff; dispatching costs more than it returns.

## Frozen contract

- `Issue::DORMANT_BUDGET_RESET = { dormant_recheck_count: 0, dormant_recheck_at: nil }.freeze`;
  `PollRouter::ResumeHandler::DORMANT_BUDGET_RESET` becomes `::Issue::DORMANT_BUDGET_RESET`.
- `Issue::COMPLETION_EVENTS = %i[mr_created discussions_fixed pipeline_fix_done].freeze`
- `Issue::DELIVERY_EVENTS = %i[pipeline_green mr_closed question_answered].freeze` — count
  only when `aasm.to_state == :done`.
- `Issue#return_dormant_budget_on_progress!` — `after_all_transitions` callback, placed
  before `persist_status_change!`. Assigns the budget reset (marking both columns changed),
  and, when `Issue.where(id:).pick(:attention_reason) == 'dormant_exhausted'`, assigns
  `needs_attention: false, attention_reason: nil, attention_detail: nil` (marked changed).
- No migration, no locale key, no config key, no new attention reason.

## Steps (TDD)

1. `test/progress_returns_the_dormant_budget_test.rb`, red first:
   - each counted event (6 cases, `pipeline_green` via its `done` branch) resets count/at
     and lifts a `dormant_exhausted` flag;
   - every other AASM event — derived from `Issue.aasm.events`, each classified in the
     test with its reason, so a new event fails until classified — leaves count, at and
     flag alone; `pipeline_green` → `reviewing` / `fixing_discussions` included;
   - a flag with another reason (`review_failures_exhausted`) survives a counted event;
   - stale object: flag written by `update_all` after load → lifted; flag cleared by
     `update_all` after load → not written back; count bumped after load → reset;
   - a stale transition (#97) writes neither;
   - #129 replay with `DormantAudit`: 4 incidents 10 days apart (mark_failed with no
     stamp → audit revive → `retry_pipeline!` → `pipeline_failed_code!` → `pipeline_fix_done!`):
     revived each time, never flagged;
   - #129 bound: the same 4 incidents with no progress between → `dormant_exhausted`;
   - re-observation bound: `fixing_discussions` stalls, audit revives to
     `checking_pipeline`, `pipeline_green!` back to `fixing_discussions`, ×4 → flagged;
   - #135: a flagged `error` row, `retry_pipeline!` → flag and count unchanged;
     then `pipeline_fix_done` (or delivery) → both cleared.
2. Implement in `app/models/issue.rb`; point `ResumeHandler` at the constant.
3. Full suite, rubocop whole tree, CHANGELOG `[Unreleased]`, CLAUDE.md sentence on the
   dormant audit row of the error table and the dormant-budget paragraph.

Test command: `RAILS_ENV=test mise x ruby@4.0.1 -- bundle exec ruby -Itest test/<file>_test.rb`;
full suite `RAILS_ENV=test mise x ruby@4.0.1 -- bin/rails test`.

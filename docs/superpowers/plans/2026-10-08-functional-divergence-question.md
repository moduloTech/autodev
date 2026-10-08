# Plan — functional divergence becomes a question (Autodev #121)

Spec: `docs/superpowers/specs/2026-10-08-functional-divergence-question-design.md`.
Tests: `mise x ruby@4.0.1 -- bundle exec ruby -Itest test/<file>_test.rb`; full suite
`mise x ruby@4.0.1 -- bin/rails test`. One lane: the files below overlap (Issue, MrFixer,
locales), so the work is done in one sequence, TDD.

## Frozen contract

- Migration `db/migrate/20261008121001_add_functional_questions_to_issues.rb`:
  `issues.functional_questions` text (JSON `{discussion_id => ISO8601 asked_at}`, NULL = none),
  `issues.clarification_resume_to` string (NULL or `'fixing_discussions'`).
- `ReviewContract::FUNCTIONAL = 'functional'`, `ReviewContract::CATEGORIES = %w[functional code]`,
  `ReviewContract.functional?(finding)`.
- `ReviewPublisher::FUNCTIONAL_MARKER = '<!-- autodev:functional -->'`.
- AASM: `event(:functional_question) { fixing_discussions → needs_clarification }`;
  `clarification_received` → `fixing_discussions` guarded by `Issue#resume_on_merge_request?`,
  else `pending`.
- `Issue::RESUME_TO_FIXING = 'fixing_discussions'`.
- `MrFixer::FunctionalQuestion` (mixin): `functional_discussion?(discussion)`,
  `ask_functional_question(issue, threads)`, `functional_answer_section(discussion)`.
- The answer is read with one `issue_notes` read per round and filtered by the existing
  `HumanActivity.human_note_after?` (no new `HumanActivity` method).
- Locale keys: `functional_question_header` (tag, mention, mr_iid), `functional_question_item`
  is not needed (numbered in code), `functional_question_footer` (tag, mr_iid),
  `review_functional_finding_label`, `activity_functional_question_asked` (count),
  `web_event_functional_question`, both fr and en.

## Steps

1. Contract: category parse/validate, `inline?` rule widened for functional; prompt schema.
   Tests in `test/review_contract_test.rb` (+ new cases).
2. Publisher: marker + label for functional; unpositioned fallback for functional without
   location or with a refused position; counted as posted. `test/a_functional_finding_is_a_thread_test.rb`.
3. Migration + Issue: columns, event, guarded transition, reentry clearing.
   `test/a_functional_question_resumes_on_the_merge_request_test.rb` (model half).
4. MrFixer: detection, ask, no count, label repose + clear on resumed round, answer section
   in the thread context. `test/a_functional_divergence_asks_the_requester_test.rb`.
5. Dispatcher/sweep: no `:process` enqueue for a row resumed to `fixing_discussions`.
6. i18n fr/en, CHANGELOG, CLAUDE.md.

## Tests the ticket requires

- POWERPANNE#14746 replay: a round over one functional thread posts a question on the
  ticket, lands in `needs_clarification`, and runs no correction (no clone, no danger-claude).
- Resume: the requester's answer brings the row to `fixing_discussions` on its MR — not
  `pending`, no `:process` job.
- A code discussion is not diverted (no question, fix cycle runs).

## Would stay green (plan adversary) → test assigned

- autodev's own question read as the answer → `test_autodev_s_own_question_is_not_the_answer`
- answer section taking autodev/system/earlier notes → `test_the_fix_context_quotes_neither_autodev_nor_gitlab`, `…_given_after_the_question`
- guard on one of its two conditions only → `test_the_guard_needs_the_merge_request`, `test_a_spec_clarification_on_a_row_with_a_merge_request_resumes_to_pending`
- stray `:process` enqueue → `test_the_answer_resumes_…` (`enqueued` empty), sweep test, `test_dispatch_discussions_picks_the_resumed_row_up`
- code threads fixed in the asking round → `test_a_round_mixing_both_asks_and_fixes_nothing`, `test_a_mixed_round_asks_only_about_the_functional_gap`
- marker read on any note → `test_a_marker_in_a_reply_is_not_the_signal`
- JSON round trip of `functional_questions` → `test_a_reloaded_row_is_never_asked_twice`
- unposted question parks the row (500 and transport) → `test_an_unposted_question_…`, `test_an_http_refusal_of_the_question_parks_nothing_either`
- columns and status in one `save!` → `test_a_row_moved_meanwhile_gets_no_wait_columns`
- counters untouched → `test_the_question_round_counts_toward_nothing` (non-zero start values)
- username vs display name → `test_the_question_names_the_gitlab_username_not_the_display_name`
- marker/label stripped, locale → `test_the_question_states_the_gap_…`, `test_the_question_is_in_the_requests_locale`
- reentry clearing → `test_reenter_clears_both_columns`, `test_reenter_to_check_pipeline_keeps_the_questions`
- prompt documents `category` → `test_the_review_prompt_asks_for_the_category`
- outage on the unpositioned fallback → `test_an_outage_on_the_unpositioned_thread_aborts_the_publication`
- budget arm → `test_a_spent_budget_still_refuses_the_resume`
- label handover on the just-resumed row through `ErasedScan`: not given its own test — the
  only label writes between the ask and the resume are autodev's, and `ErasedScan` looks for
  edits by somebody else (`label_handover.rb`), so the scan has nothing to find.

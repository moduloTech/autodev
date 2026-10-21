# Plan — a single review has no round limit (Autodev #78)

Spec: `docs/superpowers/specs/2026-10-21-a-single-review-has-no-round-limit-design.md`.
One lane (the change is a deletion across `lib/`, locale tables, tests and docs;
two lanes would share `pipeline_monitor.rb` and the test files).

## Steps

1. **Red first.** New `test/a_review_runs_once_per_merge_request_test.rb` (renamed `…_once_per_delivery_test.rb` in phase 8), real AR
   rows, real `PipelineMonitor`:
   - a green pipeline on a row at `review_count: 3` (the old limit) with no
     unresolved thread ends `done` through the nominal delivery — `label_done`,
     not flagged, no `abandon` transition;
   - the same with unresolved threads goes to `fixing_discussions`;
   - a green pipeline on a reviewed row (`review_count: 1`) never launches a
     second review (`launch_review` must not be reached);
   - `PipelineMonitor::Reviewer` no longer defines `MAX_REVIEW_ROUNDS`, and no
     `abandon_issue` site names `review_limit_reached` (derived from
     `KeySites.vocabularies[:attention_reason]`, not a grep of a literal).
   In `test/i18n_derived_keys_test.rb`, add the reverse guard: every
   `web_errors_explain_attention_<reason>` key of the tables names a reason in
   `attention_reasons`.
   Run: the new tests fail on the base for the right reason.
2. **Delete** in `lib/autodev/pipeline_monitor.rb` (`:review_limit` in
   `green_branch` / `dispatch_green`, `green_done_max_reviews`) and
   `lib/autodev/pipeline_monitor/reviewer.rb` (`MAX_REVIEW_ROUNDS`).
3. **Locales**: remove the three keys × fr/en. Touch nothing else in those files
   (Autodev #138 edits them in parallel).
4. **Comments** naming the dead path: `resume_handler.rb` (cap comment rewritten,
   see spec), `issue_abandonment.rb`, `issue.rb:132`, `poll_dispatcher.rb:368`.
5. **Tests that forced `review_count: 3`**: `issue_abandonment_test.rb`,
   `abandon_attention_label_test.rb` (drop the path; five paths remain),
   `infra_recheck_dispatch_test.rb`, `post_completion_after_unassignment_test.rb`,
   `delivered_review_card_test.rb`, `review_arrears_sweep_test.rb`,
   `database_pipeline_green_test.rb` (rename), `poll_router_reenter_test.rb`
   (comment).
6. **Docs**: `CLAUDE.md` (green routing list, diagram, error table, abandon-point
   decision), `docs/usage/autodev-technical-usage.md` (:454, :686),
   `docs/usage/autodev-functional-usage.md` (:191), `CHANGELOG.md [Unreleased]`.
7. Gate list: full suite, each changed test file alone, `bin/rubocop`.

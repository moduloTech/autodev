# Plan — a failed rebase hands back (Autodev #138)

Spec: `docs/superpowers/specs/2026-10-21-a-failed-rebase-hands-back-design.md`.
One lane (the change is ~8 files on one seam; two lanes would share the contract
file and the test file). Tests: `mise x ruby@4.0.1 -- bin/rails test`,
one file `mise x ruby@4.0.1 -- bundle exec ruby -Itest test/<f>_test.rb`.

## Steps

1. `lib/autodev/errors/rebase_conflict_error.rb` — `RebaseConflictError < AutodevError`,
   `initialize(branch:, base:, files:)`, readers, message naming branch, base, files.
   Required from `lib/autodev/errors.rb`.
2. `lib/autodev/repo_rebaser.rb`
   - `resolve_conflicts_then_continue`: read `unmerged_files` first; the danger-claude
     call alone sits in a method whose `rescue StandardError` aborts and **re-raises**
     (RateLimitError included, as before); `continue_after_resolution` runs outside it.
   - `continue_after_resolution`: ok → `finalize_rebase` (push errors propagate);
     refused → `unmerged_files` (fallback: the first read), abort, raise
     `RebaseConflictError`.
   - `unmerged_files(work_dir)` = `git diff --name-only --diff-filter=U`.
   - Header comment and outcome comment updated: no `:failed`.
3. `lib/autodev/rebase_conflict_stop.rb` — `stop_on_rebase_conflict(issue, error)`:
   `abandon_issue(issue, :rebase_conflict, detail:, branch:, base:, files:)`, then the MR
   note through `after_conclusion` when `issue.mr_iid`. Required from `lib/autodev.rb`
   (wherever the other bounds are required).
4. `app/models/issue.rb` — `abandon` sources gain `cloning`.
5. Boundaries:
   - `PipelineMonitor`: include, `rescue RebaseConflictError => e; stop_on_rebase_conflict(issue, e)`
     above `rescue StandardError` in `check`; `FailureHandler#attempt_fix`: `rescue RebaseConflictError; raise`.
   - `MrFixer`: include, rescue in `fix`; `FixCycle#execute_fix_cycle`: re-raise.
   - `IssueProcessor`: include, rescue in `process` above `rescue StandardError`.
6. Locales (fr + en, appended after the `target_branch_missing` lines, no reordering):
   `rebase_conflict`, `rebase_conflict_mr_note` (notifications), `activity_rebase_conflict`,
   `web_errors_explain_attention_rebase_conflict`.
7. Tests — `test/a_failed_rebase_hands_back_test.rb` (new) + adapt `test/repo_rebaser_test.rb`
   (the `:failed` assertions become raises).
8. CHANGELOG `[Unreleased]`, CLAUDE.md (error-handling row, `abandon` sources, rebaser).

## Tests (filled from the adversary's list)

| # | Decision | Test |
|---|---|---|
| T1 | refused `--continue` raises, naming the unmerged file, base, branch; nothing pushed; HEAD unchanged | rebaser, real git |
| T2 | danger-claude crash aborts and re-raises the original class, not RebaseConflictError | rebaser, real git |
| T3 | push failure after a resolved conflict propagates | rebaser, real git |
| T4 | fix round on a conflicting branch: `done`, `rebase_conflict`, no push, no fix prompt, MR note names the file | MrFixer, real git |
| T5 | pipeline fix: `done`, `rebase_conflict`, no fix, no review launched, no stagnation count | PipelineMonitor, stubbed rebase |
| T6 | implementation reuse path: `done` from `cloning`, implementation never called, no MR note without MR | IssueProcessor, stubbed rebase |
| T7 | locale keys exist fr+en and the comments name the files | locales + note body |

## The adversary's list, and the tests it produced

The plan adversary named ten decisions the suite above would not have caught. Each
has a test:

| Decision | Test |
|---|---|
| The files named are the ones still unmerged when `--continue` refuses, read before the abort | `repo_rebaser_test.rb` `test_the_files_named_are_the_ones_still_unmerged_when_git_refuses` (two conflicting commits, the first resolved) |
| An empty list is still a stop and both comments say no file was listed | `test_no_file_listed_is_said_on_both_comments` |
| `attention_detail` holds five paths, the comments all of them | `test_the_detail_is_bounded_and_the_comments_are_not` |
| The MR note is gated on the abandon having happened | `test_nothing_is_posted_when_the_row_cannot_be_given_up` |
| A human closing the row during the resolution: no escape, no post | `test_a_row_closed_during_the_resolution_stays_closed` — this one found a defect: `abandon!`'s `StaleTransitionError` escaped `IssueProcessor#process` from inside its rescue body; `stop_on_rebase_conflict` now rescues it |
| The review is not reached (the pipeline test was vacuous: its head pipeline is always red) | `test_no_review_can_follow_a_stopped_round`, on `IssueProcessJob::DISPATCHED_FROM[:check_pipeline]` |
| A danger-claude crash at a boundary is `error`, not a hand-back | `test_a_crash_during_the_resolution_is_not_a_hand_back`, `…_pipeline_…` |
| Not an `ApiUnavailableError` | `test_a_failed_rebase_is_not_a_member_of_the_api_unavailable_family` |
| git's `--continue` text is not published | `refute_includes body, 'needs merge'` |

# Plan — a pipeline failure lands in `error` (Autodev #128)

Spec: `docs/superpowers/specs/2026-09-29-a-pipeline-failure-lands-in-error-design.md`.
One lane (six small files); no parallel dispatch — below two lanes it costs more
than it returns.

## Contract

- `DangerClaudeRunner#safe_mark_failed!(issue, next_retry_at:)` → `true` when the
  row entered `error`, `false` when `mark_failed` was refused. On `false`:
  `issue.next_retry_at` restored to its persisted value, one `log_error` line
  naming the issue and the refused state, nothing written. `StaleTransitionError`
  still propagates.
- `Issue` event `mark_failed` sources += `checking_pipeline`.
- Every caller (`PipelineMonitor::ErrorHandler`, `MrFixer::ErrorHandler`,
  `IssueProcessor::ErrorHandler`, three methods each) returns before any write when
  `safe_mark_failed!` answers `false`.

## Steps (TDD — red first, then green)

1. `test/safe_mark_failed_decides_the_stamp_test.rb`: add
   - refused from `needs_clarification` → status unchanged, `next_retry_at`
     unchanged in DB **and** in memory, returns `false`;
   - accepted → returns `true`;
   - from `checking_pipeline` → `error`, returns `true`.
2. `test/database_error_handling_test.rb`: `mark_failed` from `checking_pipeline`
   → `error` and a `transition` activity event `checking_pipeline → error`.
3. New `test/a_pipeline_failure_lands_in_error_test.rb` (harness modelled on
   `test/prompt_context_read_is_not_a_fix_failure_test.rb`), replaying A#105:
   - a generic error raised by `write_and_categorize_jobs` (before
     `pipeline_failed_code!`) → status `error`, `next_retry_at` nil,
     `checking_pipeline_since` nil, one `pipeline_fix_error` notify;
   - two successive `check`s on the reloaded row → exactly one
     `pipeline_fix_error` notify in total (the second poll is not a pipeline
     poll any more — `dispatch_pipelines` would not select it; `check` on an
     `error` row must post nothing);
   - `RateLimitError` from the evaluation → `error` with `next_retry_at` ≈ reset;
   - a human close while the fix runs (DB row `closed`, in-memory
     `checking_pipeline`) → row stays `closed`, no `error_message`, no notify;
   - the row reaches `DormantAudit#error_arm`'s population once its activity ages.
4. Per worker, one refused-state test: each handler called on a
   `needs_clarification` row (IssueProcessor) / a row whose in-memory state is
   outside the sources (PipelineMonitor, MrFixer: `done`) → no notify, no
   `error_message`, `retry_count`/`finished_at` untouched.
5. Implement: `issue.rb` source, `safe_mark_failed!`, the nine caller gates.
6. Fix the comments that describe the old behaviour: `spec_checker.rb:119-134`,
   `failure_handler.rb:132-137` (now true — say why), `dormant_audit.rb:123-126`.
7. CLAUDE.md: the error-handling table row and the `safe_mark_failed!` sentence
   in the dormant-audit row; CHANGELOG `[Unreleased]`.
8. Gates: `mise x ruby@4.0.1 -- bundle exec rake test` (> 2777 runs, 0 failures),
   each new file run alone, `mise x ruby@4.0.1 -- bundle exec rubocop` on the
   whole tree.

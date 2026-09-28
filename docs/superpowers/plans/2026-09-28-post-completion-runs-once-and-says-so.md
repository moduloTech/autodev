# Plan — the post-completion hook runs once per delivery, and says so when it fails

Spec: `docs/superpowers/specs/2026-09-28-post-completion-runs-once-and-says-so-design.md`.
Autodev #114 + #94. Branch `fix/94-114-post-completion-runs-once-and-says-so`, off
`origin/master` (c4fac64). Test: `mise x ruby@4.0.1 -- bundle exec rake test`
(baseline 2777 runs, 0 failures). Lint: `mise x ruby@4.0.1 -- bundle exec rubocop`.

One lane: eleven files, all on the same pass, most under forty changed lines — a
fan-out would cost more than it returns.

## Frozen contract

- Column `issues.post_completion_dispatched_at`, `:datetime`, nullable, migration
  `db/migrate/20260928000001_add_post_completion_dispatched_at_to_issues.rb`
  (`if_not_exists: true`).
- `Autodev::PollDispatcher#reserve_post_completion?(issue)` — private, returns a
  boolean, compare-and-set on `id`, `project_path`, `status: 'done'`,
  `needs_attention: false`, `post_completion_dispatched_at: nil`.
- Notification keys (fr + en, `config/locales/notifications.*.yml`):
  `post_completion_exited` (`command`, `status`, `mr_url`),
  `post_completion_timed_out` (`command`, `timeout`, `mr_url`),
  `post_completion_clone_failed` (`command`, `branch`, `mr_url`),
  `post_completion_invalid_config` (`command`, `mr_url`), plus a var-free
  `post_completion_failed_footer` suffix (the delivery stands, not re-run, output
  in the dashboard, repose the todo label to replay).
- `PipelineMonitor::PostCompletion#store_pc_error(issue, error_msg, key, **vars)`
  — stores the error AND posts the comment through `notify_localized`.

## Tasks

1. **Migration** — the column. Test: `Issue.column_names` includes it (covered by
   the dispatcher tests using it; no separate test).
2. **Reservation (#114)** — `dispatch_done_unassigned` adds
   `.where(post_completion_dispatched_at: nil)`; `check_post_completion_needed`
   calls `reserve_post_completion?` after the two GitLab gates and enqueues only on
   `true`. Tests (new file `test/post_completion_runs_once_test.rb`):
   - two dispatch cycles with no job in between enqueue exactly one job;
   - the reservation is written by the dispatcher (row stamped after dispatch,
     before any job runs);
   - a row that is deferred by the MR-state gate (merged / locked) or still
     assigned is **not** stamped (the reservation comes after the gates);
   - the losing racer of the compare-and-set returns false (row already stamped);
   - a job run (success or failure) leaves the stamp in place, so the next cycle
     enqueues nothing.
3. **Clearing on reentry** — `reenter_via_pipeline_check`,
   `reenter_via_reimplementation` and `Issue.reset_for_retry!` set
   `post_completion_dispatched_at: nil, post_completion_error: nil`. Tests: one per
   writer, starting from a stamped row carrying an error.
4. **Failure signal (#94)** — `store_pc_error` posts the comment; the four failure
   paths (invalid config, clone `GitError`, non-zero exit, timeout) pass their key.
   Clone failure is rescued in `execute_post_completion`. Success posts nothing.
   Tests (new file `test/a_failed_post_completion_says_so_test.rb`), with a real
   spawn of a tiny command in a temp dir (`clone_and_checkout` stubbed to mkdir):
   - exit 3 → one comment with key `post_completion_exited`, the command and `3`;
     error stored;
   - timeout → `post_completion_timed_out`;
   - clone raises `GitError` → `post_completion_clone_failed`, error stored, no
     raise out of `run_post_completion`;
   - invalid config → `post_completion_invalid_config`;
   - success → no comment, no error;
   - the comment carries neither stdout nor stderr (the command prints a marker
     string on both, the comment must not contain it);
   - the command is scrubbed (`oauth2:<token>@` inside an argument is redacted).
5. **Unconditional transition** — `perform_post_completion` fires
   `post_completion_done!` in an `ensure`. Test: `run_post_completion` raising
   leaves the row `done` and re-raises.
6. **Declaration test** — `test/a_duplicate_job_finds_nothing_to_do_test.rb`:
   `post_completion` moves from `LATENT` to `RESERVED`; `LATENT` is removed; a
   test asserts `reserve_post_completion?` exists.
7. **i18n** — fr + en for the five keys; `test/locales_test.rb` and
   `test/i18n_derived_keys_test.rb` must stay green (literal symbols at the call
   sites).
8. **Docs** — CLAUDE.md (PollDispatcher paragraph, `dispatch_done_unassigned`
   bullet, Error Handling rows "Post-completion command fails" and "Interrupted
   running_post_completion", lifecycle diagram), CHANGELOG `[Unreleased]`.

## Sabotage targets (phase 6)

Remove the `IS NULL` filter; remove the reservation call; move the reservation
before the gates; drop each of the three clears; drop the notify in
`store_pc_error`; append stdout to the comment vars; drop the clone rescue; drop
the `ensure`.

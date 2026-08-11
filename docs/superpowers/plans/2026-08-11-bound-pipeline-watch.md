# Bounded pipeline watch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop a pipeline watch from running forever, and stop it from writing an `activity_events` row per poll (Autodev #53).

**Architecture:** Three independent changes that share one table. (1) `ActivityLogger` applies the `replace_pattern` rule to the DB row, not just the GitLab note, so a repeated activity entry is superseded in place instead of appended — which leaves `Issue.without_activity_since`'s inputs untouched and therefore leaves Autodev #50's invariant untouched. (2) A new `issues.checking_pipeline_since` column, written by one AASM callback, gives `PipelineMonitor` an absolute age bound: a poll that ends without a transition on a watch older than `pipeline_watch_max_days` (default 14) gives the ticket up as `done` + `needs_attention` (`pipeline_watch_expired`). (3) A rake task applies (1) retroactively to the 477 827 rows already accumulated, with an opt-in `VACUUM` — shipped as code, executed by a human after release.

**Tech Stack:** Rails 8.1.3, Minitest (`test/**/*_test.rb`), AASM on ActiveRecord, SQLite.

**Spec:** `docs/superpowers/specs/2026-08-11-bound-pipeline-watch-design.md`

**Predecessor:** `docs/superpowers/specs/2026-08-10-live-worker-silence-invariant-design.md` (Autodev #50) — it owns the invariant §1 must not break.

**Worktree:** `fix/53-bound-pipeline-watch` (already created, branched from `master` at `83f8c71`).

## Global Constraints

- **TDD.** Write the failing test, run it, watch it fail for the right reason, then implement.
- **RuboCop must pass**: `mise x ruby -- rubocop` from the worktree root. Never edit any `.rubocop.yml`.
- **Conventional Commits**: `<type>: <description> (Autodev #53)` plus a body explaining the why. End every commit message with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- **`CHANGELOG.md` `[Unreleased]`** is updated in the same pass. It is **not empty** — it carries four bullets from #50/#54 under `### Fixed`. Add to that section; do not create a second one.
- **Every new user-facing string goes through `Locales.t`, in both `fr` and `en`.** This change adds three keys across three locale areas.
- **Language per document.** `CHANGELOG.md` and everything under `docs/superpowers/` is English. `docs/observability.md` and `docs/usage/autodev-technical-usage.md` are **French**.
- **`docs/observability.md` renders through Redcarpet** in the dashboard: never nest a single-backtick code span inside another one.
- **NEVER run the purge against `~/.autodev/autodev.db` or `~/.autodev/autodev_queue.db`**, and never open them for writing. Tests use the in-memory test DB. No `VACUUM` outside a test.
- **Do not touch `PipelineMonitor#dispatch_status`, `#handle_green`, `#handle_red` or `FailureHandler#infra_skip?`.** Autodev #51 is rewriting the first of those on another branch. This work appends one line to `#check` and nothing else in that area.
- **Test commands** (from the worktree root):
  - one file: `mise x ruby -- bundle exec rake test TEST=test/<file>_test.rb`
  - full suite: `mise x ruby -- bundle exec rake test` (baseline on master: 1350 runs, 2608 assertions, 0 failures, 0 errors)

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `lib/autodev/activity_logger.rb` | `replace_pattern` also supersedes the DB row | 1 |
| `test/activity_logger_collapse_test.rb` | New. The collapse contract | 1 |
| `test/pipeline_watch_invariant_test.rb` | New. What the collapse does to Autodev #50 | 2 |
| `db/migrate/20260811000001_add_checking_pipeline_since_to_issues.rb` | New column + backfill | 3 |
| `app/models/issue.rb` | The clock: one AASM callback | 3 |
| `test/models/checking_pipeline_since_test.rb`, `test/migrations/backfill_checking_pipeline_since_test.rb` | New | 3 |
| `lib/autodev/pipeline_monitor/watch_bound.rb` | New module: the age bound | 4 |
| `lib/autodev/pipeline_monitor.rb`, `.../poll_tracker.rb` | Wire it in; lazy stamp | 4 |
| `lib/autodev/config.rb` | `pipeline_watch_max_days` default | 4 |
| `config/locales/{notifications,activity,web}.{fr,en}.yml` | Three keys × two languages | 4 |
| `test/pipeline_watch_bound_test.rb` | New. The bound's contract | 4 |
| `lib/tasks/autodev.rake` | `autodev:compact_activity_events` | 5 |
| `test/tasks/compact_activity_events_test.rb` | New | 5 |
| `CHANGELOG.md`, `CLAUDE.md`, `docs/observability.md`, `docs/usage/autodev-technical-usage.md` | Docs | 6 |

---

### Task 1: Collapse a replaced activity entry in the DB too

**Files:** modify `lib/autodev/activity_logger.rb`; new `test/activity_logger_collapse_test.rb`.

**Interfaces:** `ActivityLogger.post(ctx, issue, key, replace_pattern:, **vars)` keeps its signature. `persist_event!` gains a private `collapse:` kwarg. Nothing outside `ActivityLogger` changes.

- [ ] **Step 1: Failing tests.** Model them on `test/activity_logger_test.rb` (it already has a `FakeClient` and includes `DatabaseTestHelper`). Assert: two `post`s with the same key + a `replace_pattern` leave one row; the row carries the newest payload; its `created_at` advanced; without `replace_pattern` two rows remain; two different collapsible keys stay two rows; two issues stay two rows; the collapse publishes nothing to `Web::EventBus`.
- [ ] **Step 2:** implement `collapse:`, `last_collapsible_event`, `supersede!` and `like_escape` as in the spec §1. `supersede!` uses `update_columns` (no callbacks → no SSE frame). Keep the `rescue StandardError; nil` around the whole of `persist_event!`.
- [ ] **Step 3:** `mise x ruby -- bundle exec rake test TEST=test/activity_logger_collapse_test.rb` then `TEST=test/activity_logger_test.rb` (the existing file must stay green — nothing it does passes `replace_pattern`), then rubocop.
- [ ] **Commit:** `fix: collapse a replaced activity entry in the DB instead of appending one (Autodev #53)`.

### Task 2: Pin what the collapse does to the Autodev #50 invariant

**Files:** new `test/pipeline_watch_invariant_test.rb`. No production code.

This task is the ticket's stated real risk. It writes down, executably, the analysis in spec §"The constraint that governs the logging change".

- [ ] **Step 1:** a repeatedly-polled `checking_pipeline` row keeps one poll row whose `created_at` tracks the last poll, and is **not** selected by `Issue.without_activity_since(1.hour.ago)`. Same row polled 3 h ago **is** selected.
- [ ] **Step 2:** guard test — `refute_includes Issue::STALLED_STATES, 'checking_pipeline'`, same for `Autodev::HealthReport::ACTIVE_STUCK_STATES` and `PENDING_STUCK_STATES`, each with a comment naming what breaks if it ever changes.
- [ ] **Step 3:** end-to-end over the real query — `Autodev::DormantAudit#candidates` does not return a `checking_pipeline` row silent for a week.
- [ ] **Step 4:** a collapsed poll row is returned by `ActivityEvent.user_visible` (it is real activity; only `heartbeat` is machinery).
- [ ] **Commit:** `test: pin the collapse against the live-worker silence invariant (Autodev #53)`.

### Task 3: The clock — `issues.checking_pipeline_since`

**Files:** new migration `db/migrate/20260811000001_add_checking_pipeline_since_to_issues.rb`; modify `app/models/issue.rb`; new `test/models/checking_pipeline_since_test.rb` and `test/migrations/backfill_checking_pipeline_since_test.rb`.

**Interfaces:** produces `Issue#checking_pipeline_since` (datetime, NULL outside the state). Consumed by Task 4.

- [ ] **Step 1: Failing tests.** Use `DatabaseTestHelper#advance_to`. Assert the stamp on entry via `mr_created!`, the null on exit via `pipeline_green!` and `pipeline_failed_code!`, the re-stamp on `discussions_fixed!`, and that the value survives a `reload` (proving it landed in the same UPDATE as the status).
- [ ] **Step 2:** migration — `add_column :issues, :checking_pipeline_since, :datetime, if_not_exists: true` (every migration in this repo is `if_not_exists`-aware; the prod DB predates AR), then the backfill UPDATE from spec §2, guarded on `status = 'checking_pipeline' AND checking_pipeline_since IS NULL`.
- [ ] **Step 3:** model — add the column to the `attribute … :datetime` list (the surrounding columns are TEXT for legacy reasons; a fresh column is a real datetime but the list keeps one convention), and add `stamp_pipeline_watch!` as the **first** entry of `after_all_transitions`.
- [ ] **Step 4:** run both new files + `test/database_test.rb` + `test/models/` + `test/migrations/`, then rubocop.
- [ ] **Commit:** `feat: record when a request entered checking_pipeline (Autodev #53)`.

### Task 4: The age bound

**Files:** new `lib/autodev/pipeline_monitor/watch_bound.rb`; modify `lib/autodev/pipeline_monitor.rb` (require + include + one call), `lib/autodev/pipeline_monitor/poll_tracker.rb` (lazy stamp), `lib/autodev/config.rb`; six locale files; new `test/pipeline_watch_bound_test.rb`.

**Interfaces:** `WatchBound#abandon_expired_watch(issue)` — private, returns truthy when it gave the ticket up. Reads `@project_config` / `@config` for `pipeline_watch_max_days`. Uses `apply_label_done`, `notify_localized`, `log_activity`, all already mixed into `PipelineMonitor`.

**Locale keys** (`fr` and `en`, same `%{}` placeholders in both):
- `notifications`: `pipeline_watch_expired` — vars `tag`, `mr_url`, `days`.
- `activity`: `activity_pipeline_watch_expired` — vars `tag`, `days`.
- `web`: `web_errors_explain_attention_pipeline_watch_expired` — no vars.

- [ ] **Step 1: Failing tests.** `test/pipeline_monitor_infra_stagnation_test.rb` is the model: `PipelineMonitor.allocate` + `define_singleton_method` stubs for `log`, `log_activity`, `apply_label_done`, `notify_localized`, and a `FakeIssue` recording `update` calls. Cover every bullet in spec §Testing/"The age bound".
- [ ] **Step 2:** `Config::DEFAULTS['pipeline_watch_max_days'] = 14`, added to `INTEGER_FIELDS`. Do **not** add it to `DB_BACKED_PROJECT_FIELDS`.
- [ ] **Step 3:** `WatchBound` — resolution (`@project_config || @config || DEFAULTS`), `<= 0` disables, the `issue.status == 'checking_pipeline'` guard, the give-up block from spec §2.
- [ ] **Step 4:** wire it as the last statement of `PipelineMonitor#check`, and lazily stamp a NULL `checking_pipeline_since` in `PollTracker#log_pipeline_poll` next to the existing `pipeline_poll_since` stamp, with a comment naming the two `update_all` writers it covers.
- [ ] **Step 5:** run the new file, `test/pipeline_monitor_*`, `test/locales_test.rb` (it checks fr/en key parity), then rubocop.
- [ ] **Commit:** `feat: give up on a pipeline watch older than pipeline_watch_max_days (Autodev #53)`.

### Task 5: The purge, as an idempotent rake task

**Files:** modify `lib/tasks/autodev.rake`; new `test/tasks/compact_activity_events_test.rb`.

**⚠ Read the ticket's rule before writing a line:** this task is delivered as code and tested against the in-memory DB. It is **never** run against `~/.autodev/`.

- [ ] **Step 1: Failing tests.** Call the helper method directly (the rake wrapper is one line, as everywhere else in this file) so no `Rake::Task` invocation is needed. Cover: dry run deletes nothing; `APPLY` keeps the newest row per `(issue, key)`; `transition` / `heartbeat` / system rows / other `danger_claude` keys survive; a second run deletes nothing.
- [ ] **Step 2:** implement `autodev_compact_activity_events`. Per key: compute the keepers (`group(:issue_id).maximum(:id)`), then `where(...).where.not(id: keepers).in_batches(of: 10_000).delete_all`. Print a per-key report either way. `VACUUM` only when `APPLY=1 VACUUM=1`, via `connection.execute('VACUUM')`, outside any transaction.
- [ ] **Step 3:** `desc` string documents `APPLY=1` and `VACUUM=1`. Run the new test file + rubocop.
- [ ] **Commit:** `feat: add an idempotent rake task to compact accumulated poll events (Autodev #53)`.

### Task 6: Docs

- [ ] `CHANGELOG.md` `[Unreleased]` → existing `### Fixed`: one bullet per volet, in the house style (what was broken, the measured numbers, what changed, what it does **not** change about #50's invariant, and the fact that the purge is manual).
- [ ] `CLAUDE.md`: Configuration defaults list; `PipelineMonitor` section (the bound); Error Handling table (a row for "watch older than the bound" and one for the collapsed logging); Key Design Decisions — "No blocked state" must stop claiming *indefinitely*.
- [ ] `docs/observability.md` (French): in the `stuck_issues` bullet, why excluding `checking_pipeline` stays correct now that those rows only carry a collapsed entry; and a note on the sparkline no longer counting polling chatter.
- [ ] `docs/usage/autodev-technical-usage.md` (French): the per-project settings table gains `pipeline_watch_max_days` (with the same honest note `infra_recheck_max` deserves — read from `@project_config` but not a DB-backed field); the error catalog gains the abandonment row.
- [ ] **Commit:** `docs: document the pipeline-watch bound and the collapsed poll logging (Autodev #53)`.

### Task 7: Verify

- [ ] `mise x ruby -- bundle exec rake test` — no failures, no errors, run count above the 1350 baseline.
- [ ] `mise x ruby -- rubocop` — green, `.rubocop.yml` untouched (`git diff --stat` proves it).
- [ ] `git log --oneline master..HEAD` — every subject ends with `(Autodev #53)`.
- [ ] Confirm no write ever reached `~/.autodev/`.

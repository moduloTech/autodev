# auto_migrate failure handling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop `config/initializers/auto_migrate.rb` from swallowing a migration failure, so an incomplete schema — which makes every job raise `NoMethodError` in `Project#to_project_config` — can no longer run silently behind a single `warn` line (Autodev #55).

**Architecture:** Split the one `rescue` into two independent questions. **Q1** ("was this a boot-race artifact?") is a message heuristic that only chooses a log level. **Q2** ("is the schema complete?") is a set difference between the migration files and `schema_migrations`, and is the only predicate that gates anything — so no misclassification can abort a boot. Both live in a new `Autodev::MigrationStatus` (`lib/`). The initializer classifies and never raises; `bin/autodev` — which already runs the migration pass in the parent before spawning any child — gains a hard gate on Q2 before `run_supervisor`; `HealthReport` gains a `migrations` check so the entry points that still boot report the condition.

**Tech Stack:** Rails 8.1.3, SQLite (two databases: primary on `ActiveRecord::Base`, queue on `SolidQueue::Record`), Minitest (`test/**/*_test.rb`), Phlex views.

**Spec:** `docs/superpowers/specs/2026-08-11-auto-migrate-failure-handling-design.md`

**Worktree:** `fix/55-auto-migrate-failures` (already created, branched from `master` at `83f8c71`).

## Global Constraints

- **TDD.** Write the failing test, run it, watch it fail for the right reason, then implement.
- **RuboCop must pass**: `mise x ruby -- rubocop` from the worktree root. Never edit any `.rubocop.yml`.
- **Conventional Commits**: `<type>: <description> (Autodev #55)` plus a body explaining the why. End every commit message with `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- **`CHANGELOG.md` `[Unreleased]`** updated in the same pass. It is **not empty** — it carries four bullets under `### Fixed` from #50 and #54. Add to that section; do not create a second one.
- **Do not touch `~/.autodev/autodev.db` or `~/.autodev/autodev_queue.db`.** Never run anything under `RAILS_ENV=development` or `production` — both point at the real database. `RAILS_ENV=test` only.
- **Language per document.** `CHANGELOG.md`, `CLAUDE.md` and everything under `docs/superpowers/` are English. `docs/observability.md` and `docs/usage/autodev-technical-usage.md` are **French** — do not switch either.
- **`docs/observability.md` renders through Redcarpet** in the dashboard: never nest a single-backtick code span inside another one.
- **One user-facing string is added** (`web_admin_health_check_migrations`), in **both** `fr` and `en`. The `ConfigError` abort message stays raw English — see the spec §4 for why; do not "fix" it into a locale key.
- **Test commands** (from the worktree root):
  - one file: `mise x ruby -- bundle exec rake test TEST=test/<path>_test.rb`
  - one test: add `TESTOPTS="--name=/<pattern>/"`
  - full suite: `mise x ruby -- bundle exec rake test` (baseline on `master`: 1350 runs, 2608 assertions, 0 failures, 0 errors)
- **Boot proof, required by the ticket**: `RAILS_ENV=test mise x ruby -- bin/rails runner 'puts Issue.count'` must still pass after Task 4.

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `lib/autodev/migration_status.rb` | New. Answers Q1 (`benign_race?`) and Q2 (`pending`, `incomplete_schema_report`) | 1 |
| `test/services/autodev/migration_status_test.rb` | New. The taxonomy and the set difference | 1 |
| `config/initializers/auto_migrate.rb` | Classifies instead of flattening; comment corrected | 2 |
| `app/services/autodev/health_report.rb` | New `migrations` check | 3 |
| `test/services/health_report_test.rb` | Extended: the new check + the `CHECKS` key list | 3 |
| `config/locales/web.{fr,en}.yml` | `web_admin_health_check_migrations` | 3 |
| `bin/autodev` | The parent's gate, before the children are spawned | 4 |
| `CHANGELOG.md`, `CLAUDE.md`, `docs/observability.md`, `docs/usage/autodev-technical-usage.md` | Docs | 5 |

---

### Task 1: `Autodev::MigrationStatus`

**Files:**
- Create: `lib/autodev/migration_status.rb`
- Test: `test/services/autodev/migration_status_test.rb`

**Interfaces:**
- Consumes: `ActiveRecord::Base.configurations`, `ActiveRecord::MigrationContext#migrations` (filename parsing only, no connection), `SolidQueue::Record` for the queue pool.
- Produces, for Tasks 2–4:
  - `.benign_race?(error) -> Boolean`
  - `.pending -> { 'primary' => [Integer, …] }` (databases with nothing pending are omitted; `{}` means complete)
  - `.pending_versions(db_config) -> [Integer, …]`
  - `.incomplete_schema_report -> String | nil`

**Context you need:**
- The file lives in `lib/` and is loaded by a plain `require`, not Zeitwerk. Namespace it `Autodev::MigrationStatus`; `lib` is already on `$LOAD_PATH` (`test/rails_helper.rb` does `require 'autodev/locales'`).
- `pending` must **never** call `establish_connection` — the health check runs inside a live request. Resolve the connection per database name: `primary` → `ActiveRecord::Base`, `queue` → `SolidQueue::Record` when defined, anything else → skip.
- `applied_versions` must guard on `data_source_exists?('schema_migrations')` and answer `[]` when absent, and cast to `Integer` (SQLite returns the column as a string).
- The difference is `files - applied`, never the reverse: extra rows in the DB (a rollback to an older autodev) must read as complete.

- [ ] **Step 1: Write the failing tests**

`test/services/autodev/migration_status_test.rb`, `require_relative '../../rails_helper'`. Cover exactly the claims in the spec's Testing section:

Q1 — benign:
- `ActiveRecord::StatementInvalid.new('SQLite3::SQLException: duplicate column name: mr_review_timeout')`
- a `StatementInvalid` whose *message* is generic but whose `cause` carries `duplicate column name` (build it with a real `begin/rescue` so `cause` is set)
- `ActiveRecord::RecordNotUnique.new('SQLite3::ConstraintException: UNIQUE constraint failed: schema_migrations.version')`
- `'... table "projects" already exists'`
- `ActiveRecord::ConcurrentMigrationError.new`

Q1 — fatal (must be `false`):
- `SQLite3::BusyException: database is locked` (the motivating case)
- `no such table: projects`
- `RuntimeError.new('boom')`

Q2:
- `pending_versions` for the primary `db_config` is `[]` on the suite's migrated database (this is the "the gate does not trip in the normal case" assertion)
- delete one row from `schema_migrations`, assert that exact version comes back as pending, re-insert it, assert `[]` again (do the re-insert in an `ensure` so a failure cannot leave the suite's shared in-memory schema half-recorded)
- insert a bogus future version (e.g. `29999999999999`) with no file, assert `pending_versions` stays `[]`, and remove it in an `ensure`
- `incomplete_schema_report` is `nil` when `pending` is `{}` (stub `.pending`), and when `pending` is `{ 'primary' => [20260810000001] }` the message mentions `primary` and `20260810000001`

Run: `mise x ruby -- bundle exec rake test TEST=test/services/autodev/migration_status_test.rb` → must fail with `NameError: uninitialized constant Autodev::MigrationStatus`.

- [ ] **Step 2: Implement**

Write `lib/autodev/migration_status.rb`. Header comment explains the Q1/Q2 split and why only Q2 gates anything.

- [ ] **Step 3: Verify** — the file's tests pass; `mise x ruby -- rubocop lib/autodev/migration_status.rb test/services/autodev/migration_status_test.rb` is green.

- [ ] **Step 4: Commit** — `feat: add Autodev::MigrationStatus to tell a boot race from an incomplete schema (Autodev #55)`

---

### Task 2: The initializer classifies, and its comment stops lying

**Files:**
- Modify: `config/initializers/auto_migrate.rb`

**Interfaces:** consumes `Autodev::MigrationStatus.benign_race?` and `.pending_versions`. Produces nothing — it still swallows every error, by design.

**Context you need:**
- `require 'autodev/migration_status'` goes at the very **top of the file, above the two `return` guards**. The constant must exist in `test` too (Task 3's health check needs it), and the rest of the initializer no-ops there. Comment that, or someone will "tidy" it below the guards.
- **Do not add a `raise`.** The spec rejects it explicitly: it would take down `bin/rails runner`, the CLI commands, a standalone `bin/rails server` and the test suite, and it would make the abort depend on the heuristic.
- The stale claim to replace is lines 17-19: *"Safe to do here because Autodev is a single-user, single-SQLite-file CLI: no concurrent writers and no shared production database."* Replace with the real topology: the supervisor boots two Rails apps against the same file, SQLite grants no advisory lock (`supports_advisory_locks?` is `false`), the parent's own pass runs first via `config/environment`, and the loser of the race is expected to fail benignly.

- [ ] **Step 1: Implement** (no test — the initializer is unrunnable in `test`, which returns early, and in `development`/`production`, which are forbidden here; the logic it calls is fully covered by Task 1)

Split the `rescue` body into a benign branch (`Rails.logger.warn`, current wording plus the reason) and a fatal branch (`Rails.logger.error`, plus a second line naming `Autodev::MigrationStatus.pending_versions(db_config)` and pointing at `/admin/health`). Keep the per-config `establish_connection` dance and the primary restore exactly as they are.

- [ ] **Step 2: Verify** — full suite still green (it proves the new top-of-file `require` does not upset Zeitwerk's `Autodev` namespace, which `app/services/autodev/*` also occupies); `mise x ruby -- rubocop config/initializers/auto_migrate.rb`.

- [ ] **Step 3: Commit** — `fix: tell a benign migration boot race from a fatal one, and correct the concurrency comment (Autodev #55)`

---

### Task 3: The `migrations` health check

**Files:**
- Modify: `app/services/autodev/health_report.rb`
- Modify: `test/services/health_report_test.rb`
- Modify: `config/locales/web.fr.yml`, `config/locales/web.en.yml`

**Interfaces:** consumes `Autodev::MigrationStatus.pending`. Produces a `migrations` entry in the `HealthReport` envelope, `:ok` / `:down`, with `meta[:"pending_<database>"]` listing the versions.

**Context you need:**
- Append `:migrations` to `CHECKS` **after** `:database`. The existing rollup test asserts the full key list — update it in the same step, not later.
- `:down`, not `:warn`. `/healthz` answers 503 only on `down`, and an incomplete schema is a real outage.
- The view (`app/components/web/views/admin/health.rb`) needs **no change**: it builds the label key as `:"web_admin_health_check_#{name}"`. Only the two locale files change.
- In this environment the check really is `:down` (the queue in-memory database is never migrated by `test/rails_helper.rb`). Do not fight that — write the `:ok` test by stubbing `Autodev::MigrationStatus.pending` to `{}`, and the `:down` test by stubbing it to a non-empty hash. A third test can assert the real, unstubbed primary arm is `[]` — but that assertion already lives in Task 1 and does not need repeating here.

- [ ] **Step 1: Write the failing tests** in `test/services/health_report_test.rb` — `migrations` `:ok` on `{}`, `:down` with the versions in `meta` on a non-empty hash, and the updated `CHECKS` key list. Run the file, watch it fail.

- [ ] **Step 2: Implement** `check_migrations` + the `CHECKS` entry + the two locale keys (fr: `Migrations`; en: `Migrations`).

- [ ] **Step 3: Verify** — `test/services/health_report_test.rb`, `test/controllers/admin/health_controller_test.rb` and `test/controllers/monitoring_controller_test.rb` all green; rubocop on the touched files.

- [ ] **Step 4: Commit** — `feat: report an incomplete schema on /admin/health and /healthz (Autodev #55)`

---

### Task 4: The parent's gate

**Files:**
- Modify: `bin/autodev`

**Interfaces:** consumes `Autodev::MigrationStatus.incomplete_schema_report`. Produces an abort (`ConfigError` → `handle_fatal` → `exit 1`) before `run_supervisor`.

**Context you need:**
- Two edits only. Add `require_relative '../lib/autodev/migration_status'` next to the existing `require_relative '../lib/autodev/supervisor'` — explicit, rather than relying on the initializer's side effect. Then, at the **top** of `setup_database` (before `Issue.recover_on_startup!`, which would itself blow up on a missing column):

  ```ruby
  incomplete = Autodev::MigrationStatus.incomplete_schema_report
  raise ConfigError, incomplete if incomplete
  ```

- `setup_database` is called from `bootstrap`, which `main` calls **after** `handle_early_commands`. Verify by reading `main` that this ordering still holds — the whole "CLI commands are unaffected" argument rests on it.
- Do not put the gate in `lib/autodev/supervisor.rb`. The spec explains why: it is a pure process supervisor, unit-tested with an injected spawner and no ActiveRecord knowledge.
- Update `setup_database`'s leading comment, which currently states that by the time it runs "`Issue` / `ActivityEvent` are ready" — that is exactly the assumption the gate now verifies instead of assuming.

- [ ] **Step 1: Implement.**

- [ ] **Step 2: Verify** — the ticket's required boot proof: `RAILS_ENV=test mise x ruby -- bin/rails runner 'puts Issue.count'` prints `0` and exits 0. Full suite green. Rubocop green (`bin/autodev` is linted; `setup_database` is small, but check the method-length cops did not trip).

- [ ] **Step 3: Commit** — `fix: refuse to start the supervisor on an incomplete schema (Autodev #55)`

---

### Task 5: Docs

**Files:** `CHANGELOG.md`, `CLAUDE.md`, `docs/observability.md`, `docs/usage/autodev-technical-usage.md`

- [ ] **Step 1: `CHANGELOG.md`** — one bullet under the existing `[Unreleased]` → `### Fixed`, in the house style (bold lead sentence naming the user-visible consequence, then the mechanism). Say what the failure mode was, that the parent already migrated first and now verifies it, that the classification only picks a log level while the gate reads a set difference, and what an operator sees.

- [ ] **Step 2: `CLAUDE.md`** — the "SQLite Schema" section's sentence about `config/initializers/auto_migrate.rb` ("runs both on Rails boot — idempotent, every `create_table` is `if_not_exists: true`"). Extend it: the parent migrates first, a benign boot race is expected and logged as a warning, anything else is logged as an error, and `bin/autodev` refuses to spawn its children when a migration is left unapplied while every other entry point still boots.

- [ ] **Step 3: `docs/observability.md`** (French) — four edits: the JSON sample gains a `"migrations"` line; the semantics table gains a row (`ok` = tout appliqué / `down` = migration non appliquée); a bullet after the `stuck_issues` one explaining the check and why it is `down` rather than `warn`; and the `/healthz/:check` component list gains `migrations`. Watch the nested-code-span rule.

- [ ] **Step 4: `docs/usage/autodev-technical-usage.md`** (French) — one bullet in the `/admin/health` card list, after **Base de données**.

- [ ] **Step 5: Verify** — full suite, rubocop, and re-run the boot proof. Then commit: `docs: record the migration-failure taxonomy and the supervisor gate (Autodev #55)`

---

## Definition of done

- `mise x ruby -- bundle exec rake test` — 0 failures, 0 errors, run count above the 1350 baseline.
- `mise x ruby -- rubocop` — green, `.rubocop.yml` untouched.
- `RAILS_ENV=test mise x ruby -- bin/rails runner 'puts Issue.count'` — exits 0.
- `git log` shows one commit per task, each ending its subject with `(Autodev #55)`.

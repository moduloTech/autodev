# Handling `auto_migrate` failures (Autodev #55)

Date: 2026-08-11
Ticket: Skynet Autodev #55 — "`auto_migrate` avale les échecs de migration : un
schéma incomplet fait tourner l'app en panne totale, signalée par un seul
warning"

Raised by the final review of Autodev #54 (2026-08-11) while instructing the
question "is the added migration safe under the supervisor's topology?". The
answer for that migration is yes (`ALTER TABLE ADD COLUMN`, nullable, no
backfill, `if_not_exists`), but the question surfaced two problems in
`config/initializers/auto_migrate.rb`.

## Problem

### 1. A failed migration is indistinguishable from a successful one

`config/initializers/auto_migrate.rb` runs the migration pass for each
configured database inside `rescue StandardError => e` and answers with a single
`Rails.logger.warn`. Boot then continues as if nothing happened.

On SQLite `supports_advisory_locks?` is `false`, so Rails does not serialise two
migrators. Under the supervisor, `bin/rails server` and `bin/jobs start` are
spawned back to back and each boots its own Rails app against the same file.

In the ordinary case that degrades cleanly: DDL is transactional, and the loser
of the race fails either on the `UNIQUE` insert into `schema_migrations` or on
`duplicate column name` — both rescued, and in both cases the column exists
because the winner created it.

The case that hurts is different. If the `ALTER` fails in **every** process (a
30 s `busy_timeout` exhausted by an external writer, say), the application comes
up on an incomplete schema. `Project#to_project_config` calls
`public_send(:mr_review_timeout)` for every configured project, so it raises
`NoMethodError` on every job: total processing outage, not a degraded feature.
One `warn` line is the only signal.

### 2. A comment that is no longer true

The initializer still claims Autodev has "no concurrent writers". The supervisor
invalidated that a long time ago: two processes boot in parallel and each plays
the migration pass.

## Decision on point 3 — serialising the pass in the supervisor

The ticket asks this to be instructed seriously before choosing. Instructing it
turned up a fact that reframes the whole question.

**`bin/autodev` already migrates first, in the parent, before any child is
spawned.** Its third line of real work is
`require_relative '../config/environment'` — which runs
`Rails.application.initialize!`, hence the `after_initialize` block in
`auto_migrate.rb`. Only much later does `main` reach `run_supervisor` →
`spawn_all`. The children's passes are therefore already no-ops in the normal
case; the ordering the ticket proposes is the ordering we have.

So "serialise the pass in the parent" is **adopted**, but the code it needs is
not a move — it is a **verification**. The parent runs the pass and then never
checks that it worked. What is missing is a gate on the *outcome*:

```ruby
# bin/autodev, inside setup_database — after Rails booted (and therefore after
# the parent's migration pass), before the children are spawned.
incomplete = Autodev::MigrationStatus.incomplete_schema_report
raise ConfigError, incomplete if incomplete
```

`setup_database` runs inside `bootstrap`, which `main` calls **after**
`handle_early_commands`. Every path the ticket asks about is therefore
unaffected:

| Path | Reaches the gate? | Why |
|---|---|---|
| `autodev` (supervisor) | **yes** | `bootstrap` → `setup_database` |
| `autodev --status` / `--errors` / `--reset` | no | `handle_early_commands` runs first and `exit 0`s |
| `autodev --seed-admin` / `--sync-memberships` / `--link-user` | no | same early-command path |
| `bin/rails runner …` | no | never loads `bin/autodev` |
| `bin/rails server` alone (dev) | no | same |
| `bundle exec rake test` | no | same; and the initializer returns early in `test` |

That asymmetry is deliberate, not an oversight. The supervisor is the process
that starts the workers, and workers on an incomplete schema fail every job. The
other entry points are exactly the tools an operator needs *to diagnose the
incomplete schema*, plus a dashboard whose health page is where the condition is
reported. Refusing to start those would be hardening that makes the outage
harder to fix.

### Why the gate cannot produce a false positive

The ticket's corollary — "do not break the boot for hardening" — is what shaped
the design. It is met by separating two questions that the current code conflates
into one `rescue`:

**Q1 — was this exception a boot-race artifact?** A heuristic over the message
(`duplicate column name`, `already exists`, `UNIQUE constraint failed:
schema_migrations`, plus `ActiveRecord::ConcurrentMigrationError`). Its only
consequence is the log level and wording. Getting it wrong costs one line
written at the wrong severity, so it can afford to be generous towards "benign".

**Q2 — is the schema complete?** `versions parsed from db/migrate` minus
`versions recorded in schema_migrations`, per database. Not a heuristic: a set
difference between two exact sets, read *after* the pass rather than inferred
from it. **This is the only predicate that gates anything.**

The decoupling is the point. The benign race of the ticket's §1 yields a
Q1-benign exception *and* an empty Q2 answer, because the winner recorded the
version and created the column — so the gate does not trip, whatever Q1 said.
The fatal case yields an exception Q1 may well misclassify *and* a non-empty Q2
answer — so the gate trips, whatever Q1 said. **No misclassification can abort a
boot, and no misclassification can hide an incomplete schema.**

The remaining ways Q2 itself could be wrong, and why it is not:

- *DB newer than the code* (a rollback to an earlier autodev): the extra
  `schema_migrations` rows have no file, and the difference is computed in the
  other direction, so it stays empty. No trip.
- *A migration whose DDL landed but whose version was not recorded*: it trips —
  correctly. The migrator will re-run it on the next boot, and the code is not
  running against the schema it declares.
- *`schema_migrations` absent altogether* (a pass that failed wholesale on a
  fresh file): everything reads as pending. Trips, correctly.
- *A second supervisor booting concurrently, reading the diff before the first
  has committed*: out of scope, and unreachable in practice — the second
  supervisor's `bin/rails server` child cannot bind an already-taken
  `web.port`, so a second supervisor does not survive its own startup. The gate
  only ever reads the pass its own process just completed.

### Alternatives rejected

**Move the pass into `Autodev::Supervisor#run` and set
`AUTODEV_SKIP_AUTO_MIGRATE=1` on the children.** Moves nothing — the parent
already migrated, as established above — while costing two things. `Supervisor`
is a pure process supervisor, unit-tested with an injected spawner and no
ActiveRecord knowledge; giving it a database dependency drags AR into those
tests for no behavioural gain. And skipping the children's pass removes the
safety net for a child started on its own (an operator restarting only the web
process after an upgrade), replacing a harmless no-op with a new way to boot
against a schema nobody migrated.

**Raise from the initializer when the failure is classified fatal.** This is the
ticket's "empêcher le boot", read literally. Rejected on both halves of the
corollary. It takes down `bin/rails runner`, the three CLI commands, a standalone
`bin/rails server` and the test suite — for a condition whose diagnosis needs
those very tools. And it makes the abort depend on **Q1**, the heuristic, which
is precisely where a false positive would live. The gate above depends on Q2
only.

**A file lock (`flock` on `~/.autodev/migrate.lock`) around the pass.** Removes
the race — the already-benign half of the problem — and does nothing about the
fatal half, since a lock does not make an external writer release the SQLite
write lock. It also adds a file to the state directory and a stuck-lock failure
mode, and is redundant with the parent-first ordering we already have.

**Retry the pass in the gate before aborting.** Tempting, since the motivating
failure is transient. Rejected: the service manager's restart already *is* the
retry, and it is a better one (a fresh process, clean pools, no partially
initialised app). A sleep-and-retry loop in `bootstrap` silently lengthens boot
and hides the condition it is papering over.

## Design

### 1. `Autodev::MigrationStatus` — one place that answers Q1 and Q2

New file `lib/autodev/migration_status.rb`, namespace `Autodev::MigrationStatus`,
no Rails-time dependencies beyond ActiveRecord at call time.

It lives in `lib/`, not `app/services/`, on purpose. The initializer needs it,
and a plain `require` from an initializer is deterministic in every environment,
whereas referencing a Zeitwerk-autoloaded constant from `after_initialize` is a
behaviour we cannot exercise in this repo: the initializer returns early in
`test`, and `development` / `production` point at the real
`~/.autodev/autodev.db`, so the non-test path is unrunnable here. Determinism
beats idiom when the alternative cannot be tested. Precedent exists in both
directions — `Autodev::Supervisor` is `lib/`, `Autodev::HealthReport` is
`app/services/`.

```ruby
Autodev::MigrationStatus.benign_race?(error)      # Q1 -> true/false
Autodev::MigrationStatus.pending                  # Q2 -> { 'primary' => [ver, …], … }
Autodev::MigrationStatus.incomplete_schema_report # Q2 -> nil, or a printable message
```

`pending` reads each configured database through **its own** connection —
`ActiveRecord::Base` for `primary`, `SolidQueue::Record` for `queue` (the class
`config.solid_queue.connects_to` binds to that pool). It never calls
`establish_connection`: that is a boot-time hack the initializer can afford and a
health check running inside a live request cannot. Migration versions come from
`ActiveRecord::MigrationContext#migrations`, which parses filenames and touches
no connection; applied versions from a guarded
`SELECT version FROM schema_migrations`, answering `[]` when the table is absent.

### 2. The initializer: classify, never raise, and fix the comment

The `rescue` keeps its shape — boot still continues on every path — but answers
differently depending on Q1:

- benign race → `Rails.logger.warn`, as today, with the reason named;
- anything else → `Rails.logger.error`, plus a second line naming the versions
  left unapplied and pointing at `/admin/health`.

The "no concurrent writers" paragraph is replaced by an accurate one: two
processes boot in parallel, the parent migrates first, SQLite grants no advisory
lock, and the losing pass is expected to fail benignly.

The `require 'autodev/migration_status'` sits at the very top of the file,
**before** the `AUTODEV_SKIP_AUTO_MIGRATE` and `Rails.env.test?` guards, so that
the constant is available in every environment — `HealthReport` needs it in
`test`, where the rest of the initializer does nothing. `bin/autodev` requires it
explicitly as well, next to its `supervisor` require, rather than depending on an
initializer side effect.

### 3. A `migrations` health check

`HealthReport::CHECKS` gains `migrations`, appended after `database` (both are
infrastructure). It is `:down` when any database has pending migrations, `:ok`
otherwise, with the unapplied versions in `meta` as `pending_<database>`.

`:down`, not `:warn`: `/healthz` returns 503 only on a real outage, and an
incomplete schema is one — every job fails. It belongs in the paging tier
alongside "no worker alive" and "database unreachable", not in the
degraded-but-up tier.

The card label goes through `t_web(:web_admin_health_check_migrations)` (the view
builds the key from the check name), added in **both** `fr` and `en`.

In the test environment the check reads `:down`, because `test/rails_helper.rb`
migrates only the primary in-memory database and the queue one stays empty. That
is honest rather than awkward: `workers` already degrades to `:down` there for
the same underlying reason, `MonitoringController`'s tests stub the report
wholesale, and the assertions this change adds target `pending_versions` per
database rather than the rolled-up verdict.

### 4. The abort message

Raw English, via `ConfigError`, printed by `handle_fatal` as
`Config error: …` before `exit 1`. It names the affected database, the count and
the versions, says why autodev refuses to start (every job would fail), and gives
the two ways out: fix whatever held the SQLite write lock and restart, or run the
migration by hand.

Not routed through `Locales.t`, consistent with the three `ConfigError` messages
`bin/autodev` already raises during startup validation (missing projects, invalid
`gitlab_url`, missing `danger-claude`). These are pre-boot operator diagnostics on
a path where the locale is not yet resolved; introducing a locale key for the
fourth one alone would make the set inconsistent rather than more localised.

## Testing

TDD, one test per claim.

`test/services/autodev/migration_status_test.rb`:

- Q1 recognises each benign shape — `duplicate column name`, `table … already
  exists`, `UNIQUE constraint failed: schema_migrations.version`,
  `ActiveRecord::ConcurrentMigrationError` — including when the message is only
  on `error.cause` (`ActiveRecord::StatementInvalid` wraps `SQLite3::SQLException`).
- Q1 refuses the motivating fatal shape: `SQLite3::BusyException: database is
  locked`. Also `no such table`, and a bare `RuntimeError`.
- Q2 on a fully migrated database answers `[]` — the assertion that says the gate
  does not trip in the normal case, run against the suite's real migrated primary.
- Q2 reports a version deleted from `schema_migrations` as pending, and stops
  reporting it once re-inserted.
- Q2 answers `[]` when the database holds versions the files do not (the rollback
  case).
- `incomplete_schema_report` is `nil` when nothing is pending, and otherwise
  names the database and the versions.

`test/services/health_report_test.rb` (extended):

- `migrations` is `:ok` when nothing is pending (with the queue arm stubbed out,
  since it is unmigrated in this environment).
- `migrations` is `:down` and carries the versions in `meta` when something is.
- the `CHECKS` key list assertion in the existing rollup test gains `migrations`.

No test drives `bin/autodev` — it is a script with no harness. The two lines it
gains delegate to `incomplete_schema_report`, which is tested directly. The
manual proof required by the ticket is that
`RAILS_ENV=test bin/rails runner 'puts Issue.count'` still boots.

## Docs

- `CHANGELOG.md` `[Unreleased]`.
- `CLAUDE.md` — the "SQLite Schema" paragraph describing `auto_migrate.rb`, which
  currently says only "runs both on Rails boot — idempotent".
- `docs/observability.md` (French) — the checks JSON sample, the semantics table,
  a bullet for the new card, and the `/healthz/:check` component list.
- `docs/usage/autodev-technical-usage.md` (French) — one card bullet in the
  `/admin/health` section.

## Out of scope

- Serialising the pass with a lock. See Alternatives rejected.
- Making the initializer raise. See Alternatives rejected.
- Auditing the other migrations for supervisor-topology safety. #54's review
  cleared the one it was asked about; a sweep over the other 28 is a separate
  exercise, and the health check now catches the outcome regardless of the cause.
- Anything about the `queue` database's migration path beyond reporting it. It
  has a single migration and has never moved.

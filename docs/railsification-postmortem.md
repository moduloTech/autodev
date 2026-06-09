# Railsification — Post-mortem

**Window:** 2026-06-02 → 2026-06-09 (8 days end-to-end, including 3 alpha hotfixes after first deploy).
**Outcome:** `v1.0.0-alpha.3` deployed to production on 2026-06-09. AR is the authoritative data layer, Solid Queue drives the recurring poll, `bin/autodev` is a supervisor that boots `bin/rails server` + `bin/jobs start` as children, Sinatra is gone.

The historical handoff doc that tracked the work as we went lives at [`docs/archive/railsification-handoff.md`](archive/railsification-handoff.md) — this file is the after-the-fact retrospective.

## Summary

A single-file `bundler/inline` Sinatra+Sequel CLI grew into a Rails 8.1.3 application without breaking production, via a strangler-fig migration on the same SQLite file. Eight attack-order steps over five days of focused work landed all the migration; three follow-up alphas covered installer/runtime gaps that only surfaced once the Homebrew-distributed binary touched a real Mac.

## Timeline

| Date | Milestone |
|---|---|
| 2026-06-02 | Step 1 (Rails skeleton inert) + step 2 (AR models for User/Project/...) lands on the `autospec` branch |
| 2026-06-03 | Step 3 (Devise + Entra ID) + step 4 (YAML importer) + step 7 (locales → YAML). `Web::Server` mount retired — Rails serves every route. |
| 2026-06-08 | Step 5 (Solid Queue infrastructure) + step 6 (`bin/autodev` supervisor) + step 2 second half (Issue/ActivityEvent Sequel→AR). Step 8 (Phlex relocation + Sinatra deletion + libellé refresh). Rebase onto master v0.15.2. |
| 2026-06-09 | `v1.0.0-alpha.1` released. Three hotfixes (alpha.2 schedule cron, alpha.3 JobLogger). Production cuts over. |

## What went well

- **The strangler-fig pattern held.** Phase A (Rails skeleton inert next to Sinatra), phase B (Rails serving routes alongside Sinatra in one process), phase C (cutover). Each phase had a green test suite + a manual smoke check before the next started. We never had a "the whole thing is broken" half-day.
- **AASM portability paid off.** The same DSL works whether the state machine is mounted on a Sequel model or an AR model. The legacy `IssueBehavior` module ported to `app/models/issue.rb` with one-line changes (`save_changes` → `save!`). 16 states + ~25 events + ~7 guard methods migrated without state machine logic rewrites.
- **`if_not_exists: true` migrations covered both fresh installs and the existing prod DB.** No manual SQL, no per-env migration scripts. The same `db/migrate/20260608000002_create_issues_and_activity_events.rb` was a no-op against a 6-month-old prod DB and a full schema build against a fresh `:memory:` test.
- **Solid Queue is solid.** Once the schedule format was right (cron, not natural language), no other issues. The fork-based worker model under macOS launchd worked first try.
- **Test surface contracted predictably.** 575 → 452 tests — but every dropped test pointed at code that no longer ships (Sinatra Web::Server routes, Poller, WorkerPool, Database internals). Net coverage of production-reachable code stayed roughly flat.

## What went wrong

### Caught in dev, didn't ship

- **`git rebase` spuriously refused to start on 2026-06-08.** `error: Your local changes to the following files would be overwritten by merge: .gitignore, Gemfile, Gemfile.lock` against a clean tree. `git status` clean, no smudge filters, no `core.autocrlf`, no skip-worktree. `git checkout -f origin/master` worked. Workaround: `git checkout -b autospec-rebased origin/master` + cherry-pick the 10 commits one at a time. Some commits succeeded silently, some hit real conflicts (CHANGELOG.md, `lib/autodev/locales/activity.rb` modify/delete). Total cost ~30 min of confusion. Root cause never identified.
- **`pool.migration_context.migrate` lands on the wrong DB.** Multi-DB migration: each pool reports its own `db_config.name` correctly, `migrations_paths` is right, but the schema ends up on `primary` regardless. Cause: migration files use unqualified `create_table` which resolves to `ActiveRecord::Base.connection.create_table` — and `ActiveRecord::Base.connection` is whatever pool was established last, not whatever `pool` the migration code was called against. Fix: `establish_connection(db_config)` per iteration, restore primary at the end. Documented in handoff §4 for the next person.
- **`connected_to(database: :queue)` on `ActiveRecord::Base` raises `ArgumentError: unknown keyword: :database`.** The block-scoped form only works on abstract base classes that already declared `connects_to`. Tried it as a cleaner alternative to `establish_connection`-juggling; failed.

### Shipped, caught by the user's first deploy

| # | Bug | Hotfix |
|---|---|---|
| 1 | Brew formula installed only `bin/autodev` + `lib/`, not the full Rails app skeleton. `autodev` from `/opt/homebrew/bin/` couldn't find `config/environment`. | `libexec.install Dir["*"]` + `bundle install --deployment` in alpha.1 install block. |
| 2 | `#!/usr/bin/env ruby` shebang picked up mise's Ruby (4.0.2) but Brew-installed gems were compiled against Brew's Ruby (4.0.5) → `linked to incompatible libruby.4.0.dylib`. | Replaced `bin.install_symlink` with a shell wrapper that pins `Formula["ruby"].opt_bin` on PATH (alpha.1 revision 1). |
| 3 | `brew services start autodev` failed with "Formula has not implemented #plist, #service or provided a locatable service file". | Added `service do … end` block to the formula (alpha.1 revision 1). |
| 4 | launchd-inherited PATH didn't include `/opt/homebrew/bin`, so `which danger-claude` failed at bootstrap. | Wrapper PATH includes `HOMEBREW_PREFIX/bin` (alpha.1 revision 2). |
| 5 | Same root cause as #4 but for Docker Desktop: `docker` lives at `/usr/local/bin/docker` on Apple Silicon. | Wrapper PATH includes `/usr/local/{bin,sbin}` + system sbin (alpha.1 revision 3). |
| 6 | `config/recurring.yml` used `"every 300 seconds"` for the AutodevPollJob schedule. Fugit parses small N as `Fugit::Cron` but ≥60s as `EtOrbi::EoTime`. Solid Queue's `ensure_schedule_supported` validates `instance_of?(Fugit::Cron)` → rejected → `bin/jobs start` died → supervisor tore everything down. Local smoke test used `AUTODEV_POLL_INTERVAL=2` and accidentally hit the small-N path. | Emit `*/N * * * *` cron syntax instead (alpha.2). |
| 7 | Workflow code calls `logger.info(msg, project: path)` — kwargs the legacy `AppLogger` accepted but Rails' `BroadcastLogger`/`Logger` doesn't. AutodevPollJob crashed in PollDispatcher's rescue clause on the very first job. | New `Autodev::JobLogger` SimpleDelegator that overrides info/warn/error/etc. to swallow kwargs. AutodevPollJob + IssueProcessJob wrap their `logger` before handing it to workflow classes (alpha.3). |

Three of those (#4, #5, #7) would have been caught by an integration test that runs `bin/autodev` end-to-end against a sandbox SQLite + mocked GitLab + a fake danger-claude. We didn't write one because the unit tests covered the pieces and the smoke-via-`mise x ruby -- bin/rails runner ...` validated boot — but the Brew install + launchd context is genuinely different from the dev REPL and we missed those code paths.

## What I'd do differently

1. **Test the Brew install pipeline locally before tagging.** A Docker-based linuxbrew sandbox would have caught bugs #1, #2, #4, #5 before any user touched alpha.1. ~2 hours of setup, would have saved 3 hotfix releases over a 4-hour window.
2. **Don't trust Fugit's natural-language parsing across value ranges.** The same string template behaves differently for `every 2 seconds` (Cron) and `every 300 seconds` (EoTime). Cron syntax is unambiguous; use it.
3. **Logger interface is part of the contract.** When you refactor the data layer, audit every place that passes `logger` to a workflow class and decide if the new logger accepts the same shapes. Could have been caught by grep-for-`logger.info(.*,.*kwargs)`-then-test against `Logger.new(STDOUT)`.
4. **Tests grouped by deletion candidates.** When step 2b deleted ~140 obsolete Sinatra-side tests, the safer move would have been to tag them with a `LEGACY_SINATRA_TEST` marker first (one tag-commit), then delete in a separate commit. Made the diff easier to review and the rollback more granular.

## Numbers

| Metric | v0.15.2 | v1.0.0-alpha.3 |
|---|---:|---:|
| Production-reachable LOC under `lib/autodev/` | ~5,500 | ~3,400 |
| New code under `app/` | 0 | ~1,800 |
| Tests | 575 | 452 (140 obsolete dropped, 17 new) |
| Runtime gems | 17 | 16 (sequel/sinatra/sinatra-contrib dropped, solid_queue/devise/active*-session/omniauth-entra-id/omniauth-csrf added) |
| Process model | single Ruby process (poller threads + embedded Sinatra) | parent supervisor + `rails server` child + Solid Queue worker child (which forks dispatcher + scheduler + N workers) |
| Tables in primary DB | 2 (issues, activity_events) | 7 (+ users, projects, project_app_commands, project_memberships, sessions) |
| Tables in queue DB | n/a | 10 (Solid Queue) |
| Boot time (cold) | ~50 ms | ~3 s (Rails) |

## Recommendations for the next migration of similar shape

1. **Strangler fig over big-bang every time.** The 8-step ordering (`docs/autospec.md` §C) was the single most important upfront decision. Each step was independently testable; nothing left dev red.
2. **The cutover step is one commit, not a session.** Step 6 (supervisor) is the moment the new world starts driving traffic. Land it as a clean diff so the rollback is `git revert <one sha>`.
3. **Alpha early, alpha often.** Three hotfix alphas in 4 hours isn't a failure — it's the system working. The alternative is one "beta" that exposes all 7 bugs at the same time after a week of soak.
4. **Production install ≠ dev install.** Even if `mise x ruby -- ./bin/autodev` works perfectly, the Brew-installed-then-launchd-started path has different env, different Ruby ABI, different PATH. Test that path explicitly. Ideally as part of CI.

— Claude, post-railsification, 2026-06-09.

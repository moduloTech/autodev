# Railsification — Handoff

**Last updated:** 2026-06-08 (after step 2 second half — Issue/ActivityEvent Sequel→AR cutover; phase C functionally closed)
**Canonical plan:** [`autospec.md`](autospec.md) — section D (4 coexistence phases A/B/C/D) and section C (12-step attack order).

This document is the *resume-anywhere* state of the railsification. It assumes you have **no memory of previous sessions** and gives you:

1. Where we are on the plan (which coexistence phase, which attack-order step).
2. The architectural shape *right now* — what runs where, what to grep, what to avoid touching.
3. The **porting pattern** to apply for the next route off Sinatra.
4. The fresh-session sanity checks to run before changing anything.

When in doubt about *intent*, [`autospec.md`](autospec.md) is authoritative. When in doubt about *current state*, run the sanity checks in §5.

---

## 0. Terminology — two independent axes

`autospec.md` describes the migration along **two orthogonal axes** that are easy to confuse because both have a "C" in them. This document uses these names consistently:

| Axis | Source | Values | What it tracks |
|---|---|---|---|
| **Coexistence phase** | `autospec.md` **§D** | `A`, `B`, `C`, `D` | The *state of the runtime*: what processes run, what serves HTTP, what owns the DB. Discrete jumps (cutovers). |
| **Attack-order step** | `autospec.md` **§C** | `1` … `12` | The *ordered work list*: small commits that move the project forward. Steps span multiple coexistence phases. |

Examples:
- Coexistence phase A = "Rails skeleton landed but inert" (commit `7148a7c`).
- Coexistence phase B = "Rails serves routes alongside Sinatra in one process" (the 11 ports between `452d6e4` and `b03088d`).
- **Attack-order step 1** = "Squelette Rails dans le repo" — *done as the first move of coexistence phase A*.
- **Attack-order step 2** = "Modèles core + migration `issues` Sequel → AR" — *not started; will straddle coexistence phases B (add tables, no breakage) and C (cutover the readers)*.

When this doc says **"phase X"** alone, it always means a coexistence phase (§D). When it says **"step N"** alone, it always means an attack-order step (§C). When in doubt, the longer forms — **"coexistence phase X"** and **"attack-order step N"** — disambiguate.

---

## 1. State at this commit

After the 2026-06-08 rebase onto v0.15.2 (cherry-picked one commit at a time
to work around a recurring `git rebase` glitch where the apply phase
spuriously raised "your local changes would be overwritten" against a clean
tree), the history reads:

```
<HEAD>  feat: railsification step 2b — Issue/ActivityEvent Sequel→AR
11e0d9f feat: railsification step 6 — bin/autodev supervisor + Solid Queue topology
8798eb9 feat: railsification step 5 — Solid Queue poller infrastructure
ba6a564 docs(handoff): fill in step-7 commit hash in §1
1427fce feat: migrate Locales to config/locales/*.yml via I18n (step 7)
6b0776c docs(handoff): fill in phase-B-closure commit hash in §1
9fd4c3a feat: port /assets/* to Rails and drop Sinatra mount (close phase B)
ce4563a docs(handoff): fill in step-4 commit hash in §1
4022370 feat: YamlProjectImporter + rake task (railsification step 4)
331d8d1 feat: railsification step 3 — Devise + omniauth Entra ID for SSO (squashed)
6da41f4 feat: railsification step 2 — core ActiveRecord models for AutoSpec (squashed)
7de7ab2 feat: railsification phase B — Sinatra→Rails route porting (squashed)
5716053 feat: railsification phase A — Rails 8.1.3 skeleton (squashed)
3d91960 Release v0.15.2   ← master
```

A safety branch `autospec-pre-rebase-2026-06-08` preserves the pre-rebase
state of `autospec` (10 commits posed on the older v0.15.1 base) — drop it
once the next release lands.

Mapping to [`autospec.md`](autospec.md) **§D — coexistence phases**:

| Coexistence phase | Status | What was actually done |
|---|---|---|
| **A — Rails s'ajoute sans rien casser** | ✅ done | `f3bb084` (squash of original `7148a7c`): Rails 8.1.3 skeleton, AR mirror models (later removed in phase B), validation via `bin/rails runner`. Closes **attack-order step 1** (Squelette Rails). |
| **B — Rails sert des routes en parallèle de Sinatra** | ✅ done | `f16989e` (squash of 16 original commits 452d6e4..478adac): killed `bundler/inline`, mounted `Web::Server` at catch-all, ported all dynamic routes — `/issues/:id` (HTML + .json via `respond_to`), `POST /issues/:id/reset`, `POST /issues/:id/transition` (AASM `event!` from Rails — `after_all_transitions` hooks confirmed firing), `/errors`, `/projects`, `/projects/:slug` (slug decoded via `project_unslug`, no 404 on unknown — Sinatra parity), `/list/:status`, `/` (dashboard root, 5 aggregated datasets), `/issues` (paginated + filterable), `/stream` (SSE via `ActionController::Live`, `Web::EventBus` reused unchanged), `/locale/:lang` (cookie write + open-redirect-safe redirect). `<HEAD>` then closed phase B by porting `/assets/*` to `AssetsController` (3 routes, `send_file` from `lib/autodev/web/public/` — same single filesystem source of truth Sinatra reads) and **removing `mount Web::Server => '/'`** from `config/routes.rb`. `bin/rails server` now answers every URL the embedded dashboard exposes; there is no Sinatra fallback. `bin/autodev` (standalone Sinatra) is unaffected. `8a60ebc` then closed step 7: 286 locale keys migrated from three Ruby hash files to six `config/locales/{notifications,activity,web}.{fr,en}.yml`. `Locales.t` / `lookup` / `merged_for` API preserved (thin adapter on top of `i18n` gem + `Backend::Fallbacks`); ~140 callers untouched. End-to-end FR/EN switching via `/locale/en` cookie verified. **Phase B per autospec §D is fully closed.** |
| **C — Cutover du poller, décommissionnement Sinatra** | ✅ done | Steps 5 + 6 + 2b done: Solid Queue infrastructure landed (5), bin/autodev became a supervisor (6), Issue/ActivityEvent migrated Sequel→AR (2b). `--once` and `--dry-run` flags retired; `lib/autodev/poller.rb` + `lib/autodev/worker_pool.rb` + `lib/autodev/database.rb` + `lib/autodev/issue_behavior.rb` + `lib/autodev/activity_event.rb` deleted. Sequel const_set collision gone — AR `app/models/{issue,activity_event}.rb` are authoritative. Remaining: step 8 (`lib/autodev/web/` retirement, Phlex view relocation, libellé refresh) — strictly a cleanup. |
| **D — AutoSpec** | ⬜ not started | New tables (`users`, `projects`, `autospec_drafts`, etc.), Devise, Anthropic SDK chat. |

Mapping to [`autospec.md`](autospec.md) **§C — attack-order steps**:

| Step | Title | Status |
|---|---|---|
| **1** | Squelette Rails dans le repo | ✅ done (commit `f3bb084`, during coexistence phase A) |
| **2** | Modèles core (User, Project, ProjectAppCommand, ProjectMembership) + migration `issues` Sequel → AR | ✅ done — `ecf4ba4` landed the 4 new AR models; `<HEAD>` ports `Issue` + `ActivityEvent` from Sequel to AR. AASM now mounted on AR via `app/models/issue.rb` (16 states, same events, same guards as the legacy `IssueBehavior` had). `db/migrate/20260608000002_create_issues_and_activity_events.rb` is `if_not_exists`-aware so prod DBs already created by Sequel keep working unchanged. `Issue.recover_on_startup!` ports the legacy `Database::Recovery` SQL. `lib/autodev/{database,issue_behavior,activity_event}.rb` deleted; `legacy_sinatra` initializer trimmed to two lines. |
| **3** | Auth Devise + omniauth Azure AD + sessions table | ✅ done — `8af273f` wired Devise (`:trackable`, `:omniauthable`, no password module) + `omniauth-entra-id` + `activerecord-session_store`. `User.from_omniauth` factory. `/users/auth/entra_id` + `/users/auth/entra_id/callback` routes. Existing controllers NOT gated with `authenticate_user!` — Phlex dashboard stays open until per-route gates land in step 9/11. See [§4](#4-decisions-and-gotchas-that-bit-us) for the gem-require-order trap. |
| **4** | Rake idempotent d'import YAML → DB | ✅ done — `e1fce2a` landed `YamlProjectImporter` (`app/services/yaml_project_importer.rb` + `validator.rb`) and the `autodev:migrate_projects_from_yaml` task. Idempotent, transactional, dry-run safe, full validator pre-pass. **Not executed during phase B** — `lib/autodev/poller.rb` keeps reading YAML; the rake runs at the phase C cutover window per autospec §H. 30 new tests across three classes (validation, write, edge-case). |
| **5** | Réécriture poller en Solid Queue récurrente | ✅ done — `8798eb9` landed `gem 'solid_queue', '~> 1.1'`, multi-DB `config/database.yml` (primary + queue), `config/queue.yml` + `config/recurring.yml`, the `db/queue_migrate/20260608000001_create_solid_queue_tables.rb` migration, `app/jobs/{application_job,autodev_poll_job,issue_process_job}.rb`, and `app/services/autodev/poll_dispatcher.rb`. Concurrency: queue.yml `threads` from `AUTODEV_MAX_WORKERS` (default 3), IssueProcessJob's `limits_concurrency to: 1, key: "issue-#{path}-#{iid}"` for per-ticket serialization. 11 wiring tests covered the job dispatch table + AutodevPollJob's usage gate; PollDispatcher discovery-pass tests deferred (need full legacy stack to test against real `::Issue` Sequel queries). |
| **6** | `bin/autodev` superviseur | ✅ done — `<HEAD>` landed `lib/autodev/supervisor.rb` (~120 LOC, signal-trap-safe, 10s graceful TERM grace, KILL fallback) and rewired `bin/autodev`'s default mode (no `--once`) to spawn `bin/rails server -p <web.port> -b <web.bind>` + `bin/jobs start` as child processes. `bin/jobs` is a 5-line shim that requires `config/environment` then calls `SolidQueue::Cli.start(ARGV)`. Env vars (`AUTODEV_MAX_WORKERS`, `AUTODEV_POLL_INTERVAL`, `AUTODEV_DB`, `AUTODEV_QUEUE_DB`, `RAILS_ENV`) forwarded from the parent. Parent calls `Database.disconnect` after `bootstrap` so SQLite single-writer doesn't fight with the children. `--once` / `--status` / `--errors` / `--reset` / `--version` / `--help` unchanged. Queue DB pool bumped from 2 to 6 to clear Solid Queue's pool-vs-threads check (separate `queue_default` anchor; `primary` stays at 2). Smoke-tested end-to-end against a synthetic config: 2 children spawn, Solid Queue forks worker+scheduler, recurring task fires, SIGTERM tears everything down inside the grace. 5 new tests in `test/supervisor_test.rb` use an injection seam (`spawner:` + `sleeper:` kwargs) so no real `Process.spawn` fires from minitest. **Note**: `lib/autodev/poller.rb` + `lib/autodev/worker_pool.rb` + `lib/autodev/web/` are still on disk — they're kept alive by `--once` (still uses threaded poller) and a handful of legacy tests. Full deletion lands once `--once` is converted to `AutodevPollJob.perform_now` and the tests are rewritten. |
| **7** | Migration locales `lib/autodev/locales/*.rb` → `config/locales/*.yml` | ✅ done — `8a60ebc` translated 286 keys (notifications + activity + web, FR + EN) into 6 thematic YAML files. `lib/autodev/locales.rb` rewritten as adapter on `i18n` gem + `Backend::Fallbacks`. `Locales.t` / `lookup` / `merged_for` API preserved — ~140 callers untouched. Per-issue `locale: :de` (or any unknown) silently falls back to `:fr`. |
| **8** | Port des vues Phlex + refonte libellés | 🟡 partial — Phlex views ARE rendered by Rails controllers since coexistence phase B (template pattern in [§3](#3-the-porting-pattern)), but they still live under `lib/autodev/web/views/` and the libellé refactor (cf. `autospec.md` §I) hasn't happened |
| **9** | Backend AutoSpec (tables `autospec_*`, `AutospecChat` service, SSE) | ⬜ open |
| **10** | Frontend AutoSpec | ⬜ open |
| **11** | Workflow approbation | ⬜ open |
| **12** | Import GitLab d'un ticket existant | ⬜ open |

---

## 2. Architectural shape *right now*

Two entry points coexist on the same SQLite file. **Do not run both at the same time** unless you accept that both will write to the same `~/.autodev/autodev.db` (SQLite handles this via WAL + busy_timeout but it's still racy for tests).

### Entry point #1: `bin/autodev` (legacy, full stack)

- Boots via `bundler/setup` + explicit `require` block (was `bundler/inline` before `452d6e4`).
- Runs the poller in the main thread + Sinatra `Web::Server` on port `4567` (default) in a Puma thread.
- Sequel is the only DB layer. AASM is mounted on the Sequel `Issue` model (top-level constant, defined dynamically by `Database.build_model!`).
- This is what production uses today. Unchanged by phase B except for the dependency loader.

### Entry point #2: `bin/rails server` (new, Rails-hosted)

- Boots Rails 8.1.3 (`Autodev::Application < Rails::Application`).
- `config/initializers/legacy_sinatra.rb` runs at boot: requires `lib/autodev`, calls `Config.load`, opens Sequel via `Database.connect`, builds the dynamic models, hands the config to `Web::Server.configure_with`.
- `config/routes.rb` declares every URL the dashboard answers — Devise omniauth, the 11 dynamic application routes, and the 3 asset routes. **No `mount Web::Server => '/'` since phase B closed**; unknown paths 404 from Rails.
- **No poller** is running in this process. `bin/rails server` is purely the web side.

### Shared resources

- **Primary SQLite file**: `~/.autodev/autodev.db` by default. Both AR (via `config/database.yml`'s `primary` connection, pool `2`, timeout `30000`) and Sequel (via `Config.load['database_url']`) point at it. Override via `AUTODEV_DB=/tmp/x.db` — the env var is wired in both `config/database.yml` and `config/initializers/legacy_sinatra.rb`.
- **Queue SQLite file**: `~/.autodev/autodev_queue.db` by default (new in step 5). Holds Solid Queue's 10 tables (`solid_queue_jobs`, `solid_queue_ready_executions`, etc.). Override via `AUTODEV_QUEUE_DB=/tmp/q.db`. `SolidQueue::Record.connects_to(database: { writing: :queue })` is configured via `config.solid_queue.connects_to` in `config/application.rb`. Migrations live under `db/queue_migrate/`.
- **`Issue` and `ActivityEvent` constants**: in any process where the legacy_sinatra initializer ran, these are **Sequel** models with AASM. The AR mirrors that lived in `app/models/issue.rb` and `app/models/activity_event.rb` were deleted in `3fcc36b` because they collide with `Object.const_set(:Issue, klass)` from `Database.build_model!`. They come back at the step 6 cutover.

### Process diagram (current)

Default mode (`bin/autodev` with no `--once`) is now a supervisor that
spawns two children. Each child boots `config/environment` which runs the
legacy_sinatra initializer — so `Issue` / `ActivityEvent` are dynamically
defined as Sequel models on both sides.

```
bin/autodev (supervisor — production default)
└── lib/autodev/supervisor.rb
    ├── bin/rails server  → Puma → Rails (port web.port, default 4567)
    │   ├── Devise / Entra ID SSO         ← /users/auth/entra_id*
    │   ├── Dashboard / Issues / Errors / Projects / List
    │   ├── Stream (ActionController::Live SSE)
    │   ├── Locale (cookie write + redirect)
    │   └── Assets (turbo.js, css, fonts via send_file)
    │       └── Sequel datasets via legacy_sinatra initializer
    │           (controllers still call Issue / ActivityEvent /
    │            Database.db until step 2 second half ports them to AR)
    │
    └── bin/jobs start    → SolidQueue::Cli → forks 3 SQ children:
        ├── solid-queue-dispatcher  (claims scheduled jobs)
        ├── solid-queue-worker      (threads from AUTODEV_MAX_WORKERS)
        │   └── AutodevPollJob (recurring) → PollDispatcher → enqueues
        │       IssueProcessJob.perform_later(path, iid, action) per row
        │   └── IssueProcessJob → IssueProcessor / MrFixer / PipelineMonitor
        │       (legacy workers, still Sequel-backed)
        └── solid-queue-scheduler   (fires config/recurring.yml entries)

bin/autodev --once (legacy, still threaded)
└── one process
    ├── Poller.poll_loop (lib/autodev/poller.rb)
    │   └── WorkerPool threads
    └── (no embedded Sinatra — Phase B retired the mount)
```

`bin/autodev --status` / `--errors` / `--reset` open the SQLite file
directly via Sequel and exit — they do NOT go through Rails or the
supervisor. The supervisor parent calls `Database.disconnect` after its
own `bootstrap` step so the children own SQLite's single-writer lock
without contention.

---

## 3. The porting pattern

This is the recipe to follow for each remaining route in §6. The pattern was validated end-to-end on `/issues/:id.json` (commit `159785f`).

### Step 1 — Pick a route, read its Sinatra implementation

`lib/autodev/web/server.rb` is the source. Read the route block, note:
- Helpers it calls (most live in `lib/autodev/web/helpers.rb`).
- Phlex views it instantiates (`lib/autodev/web/views/**`).
- Side effects (DB writes, transitions, `redirect`, `halt`, content type).

### Step 2 — Declare the Rails route

In `config/routes.rb`, under the `# === Application routes ===` banner. Since phase B closed there is no longer a Sinatra catch-all mount — every URL has to be declared explicitly. The constraints below are kept for reference; they were tightened during the original port to avoid stealing routes from the Sinatra fallback, but the discipline is still useful for new routes (AutoSpec in step 9):

| Sinatra pattern | Rails constraint that does not steal anything else |
|---|---|
| `get %r{/issues/(\d+)\.json}` | `get '/issues/:id', to: 'issues#show', constraints: { id: /\d+/, format: 'json' }, format: true` |
| `get '/issues/:id'` (HTML) | `get '/issues/:id', to: 'issues#show', constraints: { id: /\d+/ }` (only AFTER the `.json` variant has been ported, or use `defaults: { format: 'html' }` + `format: false`) |
| `get '/'` | `root to: 'dashboard#show'` — same priority as any explicit `get '/'` |
| `post %r{/issues/(\d+)/reset}` | `post '/issues/:id/reset', to: 'issues#reset', constraints: { id: /\d+/ }` |

**`format: true` is critical** when you only want the `.json` variant. Without it, `/issues/:id` (no extension) also matches and steals the HTML route from Sinatra. This bit us once already — see [§4](#4-decisions-and-gotchas-that-bit-us).

### Step 3 — Write a thin controller

```ruby
# app/controllers/issues_controller.rb
class IssuesController < ApplicationController
  def show
    issue = ::Issue[Integer(params[:id])]
    return head :not_found unless issue
    render json: issue.values
  end
end
```

Rules of thumb in phase B:
- The data layer is **still Sequel**. `::Issue[id]`, `Database.db[:issues].where(...)`, AASM transitions — call them exactly as Sinatra does. The AR rewrite waits for phase C.
- Use `::Issue` (top-level explicit) rather than `Issue` so you don't accidentally resolve to a nested constant later.
- HTML responses can call the existing Phlex view directly: `render html: Web::Views::IssueShow.new(...).call.html_safe`. Phlex is framework-agnostic.
- For redirects: `redirect_to '/issues/123'` is the AR/Rails idiom (Sinatra used `redirect "/issues/#{id}"`).

### Step 4 — Validate byte-for-byte equivalence

```bash
# Spin up Rails on a free port
AUTODEV_DB=/tmp/test.db bin/rails server -p 3001 -b 127.0.0.1 &
sleep 5

# Compare to what Sinatra would have produced
bin/rails runner '
  rails_body   = ::Issue[1].values.to_json
  sinatra_body = JSON.generate(::Issue[1].values)
  puts "equal: #{rails_body == sinatra_body}, bytes: #{rails_body.bytesize}"
'

# Hit the live route
curl -s http://127.0.0.1:3001/issues/1.json

# Verify the un-ported HTML route still falls through to Sinatra
curl -s -o /dev/null -w "%{http_code} %{content_type}\n" http://127.0.0.1:3001/issues/1
# Expect: 200 text/html;charset=utf-8

pkill -f "rails server"
```

For HTML routes, compare the rendered Phlex output: `Web::Views::Foo.new(...).call` should produce identical strings whether called from Sinatra or Rails. If you find a diff, it's almost certainly because a helper accesses `request`/`settings` (Sinatra-specific). Move that helper to take its data as an arg.

### Step 5 — Tests + rubocop + CHANGELOG + commit

```bash
mise x ruby -- bundle exec rake test                    # 473 runs minimum, 0 failures
mise x ruby -- bundle exec rubocop app/controllers config/routes.rb
```

CHANGELOG entry under `## [Unreleased]` → `### Changed`, conventional commit (`feat: port <route> to Rails (phase B)`), include the validation commands actually run.

### Reference commit to copy from

[`159785f`](https://github.com/moduloTech/autodev/commit/159785f) — `/issues/:id.json`. 4 files, ~40 net LOC. Smallest possible port, useful as a template.

---

## 4. Decisions and gotchas that bit us

These are NOT in `autospec.md` — they were learned during execution.

### Multi-DB migrations: `pool.migration_context.migrate` lands on the wrong DB

Step 5 introduces `db/queue_migrate/` for Solid Queue. The natural-looking pattern `[ApplicationRecord, SolidQueue::Record].each { |k| k.connection_pool.migration_context.migrate }` LOOKS right (each pool's `db_config.name` is `primary` / `queue` respectively, `migrations_paths` reports the right directory) but the schema ends up on the PRIMARY DB regardless. Cause: the migration files use unqualified `create_table` which resolves to `ActiveRecord::Base.connection.create_table` — and `ActiveRecord::Base.connection` is the primary connection, not whatever `pool` the caller is iterating. Fix in `config/initializers/auto_migrate.rb`: explicitly `ActiveRecord::Base.establish_connection(db_config)` for each db config, run `MigrationContext.new(paths).migrate`, restore primary at the end. `connected_to(database: {writing: :queue})` would be the idiomatic block-scoped equivalent but **does not accept the `database:` kwarg on `ActiveRecord::Base` directly** (Rails raises `ArgumentError: unknown keyword: :database`) — that form only works on abstract classes that already declared `connects_to`.

### Solid Queue gem MUST be `require`'d in `config/application.rb`

Same trap as Devise (see "Devise + omniauth gems MUST be `require`'d in `config/application.rb`" below). Because `config/application.rb` skips `Bundler.require(*Rails.groups)`, `gem 'solid_queue'` in the Gemfile doesn't load `solid_queue.rb` at boot. If the require lives only in `config/initializers/solid_queue.rb` (or similar), the SolidQueue::Engine never registers — `config.solid_queue.connects_to` raises and `SolidQueue::Record` is undefined. The require sits at the top of `application.rb`, alongside Devise.

### `git rebase` spuriously errors with "your local changes would be overwritten"

Hit during the 2026-06-08 rebase of `autospec` onto `v0.15.2`: `git rebase origin/master` (or `--merge`, or `-i`) consistently fails on the very first commit with `error: Your local changes to the following files would be overwritten by merge: .gitignore Gemfile Gemfile.lock` — despite `git status` reporting a perfectly clean tree, no `core.autocrlf`, no smudge filters, no skip-worktree flags, and `git checkout -f origin/master` succeeding without complaint. The "your local changes" message is from `unpack-trees.c` deciding the working tree differs from the target index, but the trigger is elusive. Workaround that worked: `git checkout -b autospec-rebased origin/master`, then `git cherry-pick <sha>` for each commit one at a time (NOT batched — a batched `git cherry-pick A B C` runs into the same spurious error on the second commit). For the two commits with real conflicts (CHANGELOG.md on the phase-A entry, `lib/autodev/locales/activity.rb` deletion-vs-modification during step 7), resolve and continue. Keep a safety branch (`autospec-pre-rebase-<date>`) pointing at the pre-rebase HEAD until the next release.

### `Object.const_set(:Issue, klass)` collides with `app/models/issue.rb`

`Database.build_model!` (lib/autodev/database.rb:50) does:
```ruby
klass = Class.new(Sequel::Model(db[:issues]))
Object.const_set(:Issue, klass)
```

This is top-level. Rails autoloads `Issue` from `app/models/issue.rb` (if present) as a different class. Last-write-wins, and Phlex helpers (`Issue[id]`, `issue.aasm.events(permitted: true)`) only work on the Sequel one. The AR mirrors were removed in `3fcc36b` to resolve this. **Do not re-add `app/models/issue.rb` or `app/models/activity_event.rb` until phase C** when `lib/autodev/web/` and `Database.build_model!` are deleted.

### `format: true` on every JSON-only route

See [§3 Step 2](#step-2--declare-the-rails-route-above-the-mount). Without it, the Rails route matches BOTH `/issues/:id` and `/issues/:id.json`, and the HTML route silently dies.

### `AUTODEV_SKIP_LEGACY=1` exists for tooling

The `legacy_sinatra` initializer opens Sequel + builds models + reads `~/.autodev/config.yml`. For `bin/rails db:migrate`, `bin/rails db:schema:dump`, or one-off `bin/rails runner` snippets that should NOT touch Sequel, prepend `AUTODEV_SKIP_LEGACY=1`. The `if defined?(Web::Server)` guard in `routes.rb` makes the mount line a no-op when the initializer was skipped.

### `lib/autodev.rb` now requires its gem deps

Was previously auto-required by `bundler/inline` in `bin/autodev`. Now lives at the top of `lib/autodev.rb`. If you add a new gem dependency that any `lib/autodev/*.rb` uses, add it BOTH to `Gemfile` and to that explicit require list — both `bin/autodev` and Rails depend on it.

### Rails autoload path is `app/` only

`add_autoload_paths_to_load_path = false` is set, and there's no `autoload_lib` call. So `lib/autodev/*.rb` is NOT autoloaded by Zeitwerk — it's loaded via the explicit `require_relative '../../lib/autodev'` in the legacy_sinatra initializer. **Do not** try to make Rails autoload `lib/` — the legacy modules don't follow Zeitwerk's naming conventions, and pulling them in via autoload would trigger constant-resolution loops.

### Rails 8 `allow_browser versions: :modern` was removed

`ApplicationController` no longer includes `allow_browser`. Sinatra accepts all User-Agents and gating ported routes on a modern-browser filter would 406 curl, scripts, and the NetBird-mesh dashboard. A conscious modern-browser policy can come back once phase B is done.

### CSRF protection vs Phlex forms (still Sinatra-rendered)

`ApplicationController < ActionController::Base` enables CSRF protection by default. The Phlex forms in `lib/autodev/web/views/**` do NOT emit `csrf_meta_tags` (Sinatra has no CSRF) and currently render the dashboard the user actually clicks on. Without intervention, the first ported write action 422s every form submission as missing authenticity token.

Workaround for the duration of phase B: `skip_forgery_protection only: %i[action1 action2]` on controllers that handle Phlex-rendered forms, scoped per-action. Add the action to the only-list each time you port a write path; never blanket-skip on the whole controller. When the layout moves to Rails-rendered ERB with `csrf_meta_tags`, the skips come off action by action.

The proper long-term fix is to make the Phlex Layout emit a CSRF meta tag (a master_session-bound nonce that the form helpers can read). That can wait until the layout itself is ported.

### `respond_to` order matters under `Accept: */*`

When porting a route that serves multiple formats (e.g. `/issues/:id` HTML + `.json`), Rails' `respond_to` picks the FIRST registered format whose mime-type matches `*/*`. curl, the dashboard's inline-`fetch` without an Accept header, and most scripts send `*/*` — they get the first format. Sinatra defaults to HTML for these; if you put `format.json` before `format.html`, every plain `curl /issues/1` will silently get JSON and the HTML route is effectively dead. Always put `format.html` first when a route serves both. Caught and fixed during the `/issues/:id` HTML port.

### `bin/rails db:migrate` is NOT a registered command — use the auto_migrate initializer

The skeleton in `7148a7c` loads only a minimal set of railties (`active_model`, `active_record`, `action_controller`, `action_view`) and skips `Bundler.require(*Rails.groups)`, so the `Rails::Command::Behavior` lookup never finds `db:migrate`, `db:create`, etc. `bin/rails --help` lists only `db:system:change` under "db". This contradicts the previous version of this doc — the handoff §4 used to claim `bin/rails db:migrate` worked. It doesn't, and it's been working around this since step 2:

- **In production / dev**: `config/initializers/auto_migrate.rb` runs pending migrations on `Rails.application.config.after_initialize`. Idempotent. Skipped in test env (the test helper migrates against `:memory:` explicitly) and when `AUTODEV_SKIP_AUTO_MIGRATE=1`.
- **In tests**: `test/rails_helper.rb` calls `ActiveRecord::MigrationContext.new(Rails.root.join('db/migrate').to_s).migrate` directly after booting `config/environment`.
- **Ad-hoc / scripts**: `bin/rails runner '...MigrationContext.new(...).migrate'` is the manual escape hatch.

If you ever want `bin/rails db:migrate` back, the path is to require the missing railtie tasks explicitly in `config/application.rb` — but be careful not to also re-enable the autoload-lib path, which would pull the Sequel modules into the Rails process.

### Devise + omniauth gems MUST be `require`'d in `config/application.rb`, not in their initializer

`config/application.rb` skips `Bundler.require(*Rails.groups)` (to keep Sequel/Sinatra out of the Rails process). That means `gem 'devise'` in the Gemfile doesn't load `devise.rb` at boot. If you put `require 'devise'` only in `config/initializers/devise.rb`, the require happens **after** Rails initializers have already collected `Rails::Engine.subclasses` — Devise's engine never registers its `app/controllers/devise/*` autoload paths, and `Devise::OmniauthCallbacksController` won't resolve at boot. Symptom: `uninitialized constant Devise::OmniauthCallbacksController` deep in route resolution. Fix lives at the top of `config/application.rb`:

```ruby
require 'devise'
require 'omniauth-entra-id'
require 'omniauth/rails_csrf_protection'
```

Same trap for `ActionDispatch::Session::ActiveRecordStore` — `config/initializers/session_store.rb` does `require 'action_dispatch/session/active_record_store'` because the `activerecord-session_store` gem is otherwise never loaded.

### Devise needs an explicit `secret_key` under our minimal railtie set

`Devise.setup do |config|` blocks normally pick up `config.secret_key = Rails.application.secret_key_base` automatically. With our pared-down railtie set the secret_key_base isn't always populated at initializer time. `config/initializers/devise.rb` sets it explicitly with a `SecureRandom.hex(64)` fallback so `bin/rails routes` / runner don't crash with `Devise.secret_key was not set`.

### Existing controllers stay open — auth gates land later

Step 3 wires Devise machinery (provider, callback controller, sessions) but **does not** add `before_action :authenticate_user!` to `ApplicationController` or any existing controller. The Phlex dashboard (Rails-served since phase B finished) keeps answering `GET /` to anyone hitting localhost / the NetBird mesh, matching production `bin/autodev` behavior. Per-route gates will land with the routes that actually need them — step 9 (AutoSpec greenfield routes) and step 11 (workflow approbation). Today there is no users row in production, so adding a global gate would lock everyone out of the dashboard with no way back in.

### `OmniAuth.config.test_mode = true` is fragile with the Devise + csrf-protection stack

Direct `post '/users/auth/entra_id/callback'` from an integration test does NOT plumb `mock_auth[:entra_id]` into `env['omniauth.auth']` in our setup — the strategy class' `client` method runs against nil credentials and crashes before the mock callback path triggers. Going through the request phase first (`post '/users/auth/entra_id'` then `follow_redirect!`) similarly trips on the strategy initialization. Three options if you need to test the full flow later: (a) inject `env['omniauth.auth']` directly into `request.env` via a custom `Rack::Test`-style setup, (b) stub `User.from_omniauth` and assert only the callback shape, (c) accept this and rely on the wiring tests in `test/controllers/users/omniauth_callbacks_controller_test.rb` plus the exhaustive `User.from_omniauth` coverage in `test/models/user_omniauth_test.rb`. We took option (c) — the controller body is 10 lines and the integration coverage cost was too high.

### `ActiveRecord::TestFixtures` can't be required in plain `rake test`

Trying `require 'active_record/test_fixtures'` (or `active_record/test_help`) from a non-railtie-driven test boot triggers a Zeitwerk circular require: `test_fixtures.rb` requires `fixtures.rb` which (under the autoloader) tries to autoload `ActiveRecord::TestFixtures` and re-enters. `test/rails_helper.rb` therefore uses manual per-test cleanup (`DELETE FROM` the four step-2 tables in `teardown`) instead of transactional tests. SQLite `:memory:` makes this essentially free. If you add more AR-backed tables later, extend the `TABLES` list in `ActiveRecordTestCleanup`.

### Tests live under `test/` (minitest, not Rails::TestUnit)

The existing `Rakefile` uses `Rake::TestTask` and DOES NOT call `Rails.application.load_tasks`. `bin/rake -T` only lists `rake test`. Rails tasks (migrations etc.) are accessed via `bin/rails db:migrate` — they go through `Rails::Command`, not Rake. **Do not** add `Rails.application.load_tasks` to the Rakefile in phase B; it would conflict with the existing minitest harness.

---

## 5. Fresh-session sanity checks

Run these in order from a clean shell to confirm the state matches what this doc claims. If any of them disagrees with the expected output, **stop and re-read the relevant commit** before changing anything.

```bash
cd /home/claude/tooling/autodev

# 1. Right commit at HEAD
git log --oneline -1
# expect a feat/refactor commit related to the railsification
# (coexistence phase A/B/C/D or an attack-order step — both are
#  legitimate railsification work)

# 2. Both entry points exist
ls bin/autodev bin/rails

# 3. Rails boots and reads the existing Sequel DB
AUTODEV_DB=/tmp/sanity.db mise x ruby -- bundle exec ruby -e '
  require "sequel"; require_relative "lib/autodev/database/migration"
  Database::Migration.run(Sequel.connect("sqlite:///tmp/sanity.db"))
'
AUTODEV_DB=/tmp/sanity.db mise x ruby -- bin/rails runner 'puts "Issue: #{Issue.count}, AE: #{ActivityEvent.count}"'
# expect: "Issue: 0, AE: 0" (empty fresh DB) — and zero Ruby errors

# 4. Test suite still green
mise x ruby -- bundle exec rake test
# expect: "452 runs, 785 assertions, 0 failures, 0 errors, 0 skips"
# (step 2b deleted ~140 obsolete Sinatra-side tests and ~13 Poller/WorkerPool
# /Database internal tests — net 452. New tests will be added as new code
# lands in step 8 + AutoSpec.)
# (number grows as new tests land; step 2 raised the baseline from 473 to 498
#  with 20 AR model tests + 5 splits for Minitest/MultipleAssertions;
#  step 3 added 10 more — 6 on User.from_omniauth, 4 on the omniauth callback
#  controller wiring; the 2026-06-08 rebase onto v0.15.2 folded in master's
#  rate_limit_detector / repo_rebaser / poll_router_reenter /
#  pipeline_monitor_review_failure tests + the merged-MR reentry-skip test;
#  step 4 added 30 importer tests; step 5 added 11 job wiring tests;
#  step 6 added 5 supervisor tests)

# 5. Rubocop clean on the files we own
mise x ruby -- bundle exec rubocop app/controllers app/jobs app/models app/services \
  bin/autodev bin/jobs config/routes.rb config/application.rb \
  config/initializers/legacy_sinatra.rb config/initializers/auto_migrate.rb \
  db/migrate db/queue_migrate lib/autodev/supervisor.rb lib/tasks/autodev.rake \
  test/jobs test/models test/services test/supervisor_test.rb test/rails_helper.rb
# expect: "1 offense detected" (the pre-existing Style/Documentation on the
#  generated `app/models/application_record.rb` — not worth fixing yet).
# Running rubocop against the whole tree reports ~54 offenses, all in
# Rails-generated files (bin/bundle, bin/rubocop, bin/setup, config/puma.rb,
# config/initializers/*, db/seeds.rb, ...) introduced by `7148a7c` and never
# excluded from .rubocop.yml. NOT a regression from any porting work.
# Per repo CLAUDE.md, `.rubocop.yml` is maintained separately — do not edit it
# to suppress these.

# 6. The first ported route still works end-to-end
AUTODEV_DB=/tmp/sanity.db mise x ruby -- bin/rails server -p 3001 -b 127.0.0.1 >/tmp/rails.log 2>&1 &
sleep 6
curl -s -o /dev/null -w "%{http_code} %{content_type}\n" http://127.0.0.1:3001/issues/999.json
# expect: "404" with no content-type set, or text/html
curl -s -o /dev/null -w "%{http_code} %{content_type}\n" http://127.0.0.1:3001/
# expect: "200 text/html;charset=utf-8" (Sinatra dashboard fallback)
pkill -f "rails server"
```

---

## 6. Next route to port

The candidates ordered by complexity (lowest first):

| Route | Complexity | Notes |
|---|---|---|
| ~~`GET /issues/:id` (HTML)~~ | ✅ done | Ported with `/issues/:id.json` via `respond_to`. Pattern proven: include `Web::Helpers`, build kwargs hash (`locale:`, `request_path:` + view-specific), `render html: phlex.call.html_safe, layout: false`. `format.html` MUST come first in `respond_to` so `Accept: */*` gets HTML. |
| ~~`POST /issues/:id/reset`~~ | ✅ done | Raw SQL UPDATE (not AASM) + `redirect_to`. Required `skip_forgery_protection only: %i[reset]` because Phlex forms have no CSRF token — see [§4](#4-decisions-and-gotchas-that-bit-us). Validated by seeding an `error` row and verifying the row clears post-POST. |
| ~~`POST /issues/:id/transition`~~ | ✅ done | Calls `issue.send("\#{event}!")` — AASM transitions from Rails confirmed to fire `after_all_transitions :persist_status_change!, :emit_activity_event!`. Same `skip_forgery_protection` opt-in (now `%i[reset transition]`). Returns `422 Unprocessable Entity` with body `Event 'X' not permitted from Y` for events not in `permitted_events_for(issue)`. |
| ~~`GET /errors`~~ | ✅ done | `ErrorsController#index`. Query: `where(status: %w[error needs_clarification]).or(Sequel.~(post_completion_error: nil)).order(Sequel.desc(:id))`. Phlex view reused as-is. Byte-identical (21713 bytes both paths). |
| ~~`GET /projects`~~ | ✅ done | `ProjectsController#index`. Builds union(YAML config paths, DB-distinct paths), fills with `project_breakdown` stats or zero-filled placeholder. Byte-identical (13770 bytes with the test seed). |
| ~~`GET /projects/:slug`~~ | ✅ done | `ProjectsController#show`. Slug decoded via `project_unslug` (`__` → `/`). **No 404 on unknown slug** — Sinatra parity (renders empty page). `?tab=...` query param passes through. Byte-identical (18389 bytes for an existing project). Default Rails route constraint (no `/`, no `.`) accepts `group__project` slugs unchanged. |
| ~~`GET /list/:status`~~ | ✅ done | `ListController#show`. Single dataset filter + Phlex view. No allowlist on `:status` (Sinatra parity — unknown status renders empty list). Byte-identical at 3 statuses (pending 4172, done 4022, nonexistent 3868). |
| ~~`GET /` (dashboard root)~~ | ✅ done | `DashboardController#show`, `root to: 'dashboard#show'`. 5 datasets: `active_issues`, `errored` (inline query, same as `/errors`), `dashboard_kpis`, `weekly_activity_counts`, `project_breakdown`. Byte-identical (28825 bytes with the test seed). |
| ~~`GET /issues`~~ | ✅ done | `IssuesController#index`. Uses 7 IssuesFilter helpers (`per_page_for`, `page_for`, `filter_issues`, `paginate`, `tab_param`, `tab_counts`, `dashboard_kpis`). Byte-identical at 5 param combos. Rails' `ActionController::Parameters` works as a drop-in for the Sinatra params hash. |
| ~~`GET /stream` (SSE)~~ | ✅ done | `StreamController#show` via `include ActionController::Live`. Reuses `Web::EventBus.subscribe`/`unsubscribe` and `Web::Helpers#format_sse` unchanged. Loop on `queue.pop`, write to `response.stream`, rescue `IOError`/`ClientDisconnected`. Byte-identical (799 bytes for one transition event). |
| ~~`GET /locale/:lang`~~ | ✅ done | `LocaleController#update`. `apply_locale_cookie!` works unchanged (Rack-standard `response.set_cookie` / `delete_cookie`). `safe_back_path` keeps the open-redirect guard intact. 4 curl cases validated (valid, with back, invalid → cookie cleared, evil-back stripped). |
| ~~Static asset routes (`/assets/css/*`, `/assets/turbo.js`, `/assets/vendor/fonts/*`)~~ | ✅ done | `AssetsController#turbo_js` / `#css` / `#font` `send_file` from `lib/autodev/web/public/`. `skip_forgery_protection` (Rails' cross-origin-JS guard 422s `<script src>` without Referer; static public files don't need it). Same single filesystem source `bin/autodev`'s Sinatra still reads, so step 8 can swap to propshaft without touching source files. End-to-end: turbo.js 217020b, app.css 17529b, sample font 18748b — all 200 with the right content-type. |

**Coexistence phase C is done per autospec §D.** Phase B was closed already (all routes Rails-native, Devise/Entra ID wired, locales in YAML). Phase C: step 5 (Solid Queue infrastructure), step 6 (supervisor), and step 2 second half (Issue/AE Sequel→AR) all landed. Default `bin/autodev` boots Rails + Solid Queue subprocesses and AR `Issue` is authoritative end-to-end. The only railsification work left is **step 8** — a cleanup pass that retires `lib/autodev/web/` (Phlex views relocated to `app/views/`, propshaft replaces `AssetsController`, libellé refresh per autospec §I).

**Recommended next: step 8.** It's strictly cosmetic (the dead `lib/autodev/web/server.rb` deletion plus Phlex view relocation) but it cleans up the last piece of cross-codebase weight.

Steps 1, 2, 3, 4, 5, 6, 7 are ✅ done; step 8 ⬜.

Attack-order steps that remain:

- **Step 8 — Phlex view port + propshaft + libellé refactor**: delete `lib/autodev/web/server.rb` + `lifecycle.rb` (dead code since phase B retired the Sinatra mount), move `lib/autodev/web/views/**` → `app/views/`, replace `AssetsController#send_file` with propshaft, refresh the libellé vocabulary per autospec §I. `Web::Helpers`, `Web::EventBus`, `Web::I18nHelpers`, `Web::IssuesFilter`, `Web::TurboStreamHelpers` move alongside (probably to `app/helpers/` + `app/services/` depending on shape). `lib/autodev.rb` drops `require_relative 'autodev/web'`; `bin/autodev` no longer transitively loads sinatra/base. Should also drop the `require 'sinatra/base'` line in `lib/autodev/web.rb` itself — and the file becomes empty enough to delete.

---

## 7. Pointers

| If you want… | Look at |
|---|---|
| The plan and rationale | [`autospec.md`](autospec.md) §C (attack order) and §D (3 phases) |
| What the legacy stack does | [`../CLAUDE.md`](../CLAUDE.md) — single-file CLI overview |
| Where Sinatra routes live | `lib/autodev/web/server.rb` |
| Where Phlex views live | `lib/autodev/web/views/**/*.rb` |
| How AASM is wired | `lib/autodev/issue_behavior.rb` + `lib/autodev/database.rb:50` |
| How config is loaded | `lib/autodev/config.rb` (`Config.load`) |
| How Rails boots Sequel | `config/initializers/legacy_sinatra.rb` |
| The current Rails autoload + railtie set | `config/application.rb` |
| Database file path resolution (both sides) | `config/database.yml` (AR) and `lib/autodev/config.rb` (Sequel); both default to `~/.autodev/autodev.db`, both honor `AUTODEV_DB` env var |

---

## 8. What to do FIRST in a new session

1. Read this file end-to-end (you're doing that now).
2. Skim [§D of autospec.md](autospec.md) for the phase plan.
3. Run [§5 sanity checks](#5-fresh-session-sanity-checks) — every one. **Do not** start coding until they all pass; if one fails, find the regression and report it instead of working around it.
4. Pick the next route from [§6](#6-next-route-to-port) (or ask the user).
5. Follow [§3 porting pattern](#3-the-porting-pattern) step-by-step.
6. Update this handoff doc at the end of the session — the "State at this commit" section, gotchas if any new ones surfaced, and the "Next route" table.

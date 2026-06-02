# Railsification — Handoff

**Last updated:** 2026-06-02 (after landing step 2 — core AR models for AutoSpec)
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

```
90bcabb feat: add core AR models for AutoSpec (railsification step 2)
478adac docs(handoff): disambiguate "phase X" vs "step N" naming
b03088d feat: port GET /locale/:lang to Rails controller (phase B)
ebb8581 feat: port GET /stream (SSE) to Rails controller (phase B)
b788b55 feat: port GET /issues (paginated list) to Rails controller (phase B)
daf5bf3 feat: port GET / (dashboard root) to Rails controller (phase B)
8244c21 feat: port GET /list/:status to Rails controller (phase B)
e6cd6f7 feat: port GET /projects/:slug to Rails controller (phase B)
8dec203 feat: port GET /projects to Rails controller (phase B)
a61b391 feat: port GET /errors to Rails controller (phase B)
fb4f261 feat: port POST /issues/:id/transition to Rails controller (phase B)
3608bab feat: port POST /issues/:id/reset to Rails controller (phase B)
8dad64b feat: port GET /issues/:id (HTML) to Rails controller (phase B)
eed8127 docs: add railsification handoff guide for resume-from-clean-session
159785f feat: port GET /issues/:id.json to Rails controller (phase B)
3fcc36b feat: mount legacy Sinatra Web::Server as Rails route (phase B)
452d6e4 refactor: drop bundler/inline in bin/autodev (phase B railsification start)
7148a7c feat: add Rails 8.1.3 skeleton (phase A railsification)
```

Mapping to [`autospec.md`](autospec.md) **§D — coexistence phases**:

| Coexistence phase | Status | What was actually done |
|---|---|---|
| **A — Rails s'ajoute sans rien casser** | ✅ done | `7148a7c`: Rails 8.1.3 skeleton, AR mirror models (later removed), validation via `bin/rails runner`. This commit also closes **attack-order step 1** (Squelette Rails). |
| **B — Rails sert des routes en parallèle de Sinatra** | 🟡 in progress | `452d6e4` killed `bundler/inline`. `3fcc36b` mounted `Web::Server` at the catch-all route. `159785f` ported `/issues/:id.json`. `8dad64b` extended the same controller to serve the HTML variant via `respond_to`. `3608bab` ported `POST /issues/:id/reset` (first write path). `fb4f261` ported `POST /issues/:id/transition` (AASM `event!` from Rails — `after_all_transitions` hooks confirmed firing). `a61b391` ported `GET /errors` (first standalone controller). `8dec203` ported `GET /projects`. `e6cd6f7` ported `GET /projects/:slug` (slug decoded via `project_unslug`, no 404 on unknown — Sinatra parity). `8244c21` ported `GET /list/:status`. `daf5bf3` ported `GET /` (dashboard root) — 5 aggregated datasets, biggest view so far. `b788b55` ported `GET /issues` (paginated + filterable list). `ebb8581` ported `GET /stream` (SSE via `ActionController::Live`, `Web::EventBus` reused unchanged). `<HEAD>` ported `GET /locale/:lang` (cookie write + open-redirect-safe redirect). **All dynamic routes are now Rails-native.** Only `/assets/*` remains on Sinatra (static files: vendored Turbo, CSS, woff2 fonts) — to be re-routed when phase C wires up propshaft. Routes left to port: see §6. Devise + omniauth Azure AD: not started. Locale migration to `config/locales/*.yml`: not started. |
| **C — Cutover du poller, décommissionnement Sinatra** | ⬜ not started | Solid Queue, `bin/autodev` supervisor, AR Issue becomes authoritative, `lib/autodev/web/` deleted. |
| **D — AutoSpec** | ⬜ not started | New tables (`users`, `projects`, `autospec_drafts`, etc.), Devise, Anthropic SDK chat. |

Mapping to [`autospec.md`](autospec.md) **§C — attack-order steps**:

| Step | Title | Status |
|---|---|---|
| **1** | Squelette Rails dans le repo | ✅ done (commit `7148a7c`, during coexistence phase A) |
| **2** | Modèles core (User, Project, ProjectAppCommand, ProjectMembership) + migration `issues` Sequel → AR | 🟡 partial — `<HEAD>` landed the 4 new AR models + migrations + 20 model tests (purely additive on the DB side, tables sit empty during phase B). The `issues` Sequel→AR migration is the remaining half; still waits for phase C because of the `Object.const_set` collision (see [§4](#4-decisions-and-gotchas-that-bit-us)). |
| **3** | Auth Devise + omniauth Azure AD + sessions table | ⬜ open |
| **4** | Rake idempotent d'import YAML → DB | ⬜ open (depends on step 2 tables) |
| **5** | Réécriture poller en Solid Queue récurrente | ⬜ open |
| **6** | `bin/autodev` superviseur | ⬜ open |
| **7** | Migration locales `lib/autodev/locales/*.rb` → `config/locales/*.yml` | ⬜ open |
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
- `config/routes.rb` declares any Rails-native routes ABOVE `mount Web::Server => '/'`. Rails router matches top-down, so anything not declared falls through to Sinatra.
- **No poller** is running in this process. `bin/rails server` is purely the web side.

### Shared resources

- **SQLite file**: `~/.autodev/autodev.db` by default. Both AR (via `config/database.yml`, pool `2`, timeout `30000`) and Sequel (via `Config.load['database_url']`) point at it. Override BOTH at once by setting `AUTODEV_DB=/tmp/x.db` — the env var is wired in both `config/database.yml` and `config/initializers/legacy_sinatra.rb`.
- **`Issue` and `ActivityEvent` constants**: in any process where the legacy_sinatra initializer ran, these are **Sequel** models with AASM. The AR mirrors that lived in `app/models/issue.rb` and `app/models/activity_event.rb` were deleted in `3fcc36b` because they collide with `Object.const_set(:Issue, klass)` from `Database.build_model!`. They come back in phase C.

### Process diagram (current)

```
bin/autodev (production)
└── one process
    ├── poller threads (lib/autodev/poller.rb + worker_pool.rb)
    └── embedded Puma → Sinatra::Web::Server (port 4567)
        └── Sequel datasets (Database.db, Issue, ActivityEvent)

bin/rails server (new, transitional)
└── one process
    └── Puma → Rails (port 3000)
        ├── IssuesController#show         ← Rails-native, /issues/:id.json
        └── mount Web::Server => '/'      ← Sinatra fallback for everything else
            └── same Sequel datasets (legacy_sinatra initializer wired them)
```

---

## 3. The porting pattern

This is the recipe to follow for each remaining route in §6. The pattern was validated end-to-end on `/issues/:id.json` (commit `159785f`).

### Step 1 — Pick a route, read its Sinatra implementation

`lib/autodev/web/server.rb` is the source. Read the route block, note:
- Helpers it calls (most live in `lib/autodev/web/helpers.rb`).
- Phlex views it instantiates (`lib/autodev/web/views/**`).
- Side effects (DB writes, transitions, `redirect`, `halt`, content type).

### Step 2 — Declare the Rails route ABOVE the `mount`

In `config/routes.rb`, between the `# === Ported routes ===` banner and `mount Web::Server => '/'`. **Use the tightest possible constraint** so you don't steal not-yet-ported routes:

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
# expect: "498 runs, 895 assertions, 0 failures, 0 errors, 0 skips"
# (number grows as new tests land; baseline rose from 473 to 498 when step 2
#  added 20 AR model tests; the +5 between "473+20=493" and "498" is the test
#  splitting for Minitest/MultipleAssertions)

# 5. Rubocop clean on the files we own
mise x ruby -- bundle exec rubocop app/controllers app/models config/routes.rb \
  config/initializers/legacy_sinatra.rb config/initializers/auto_migrate.rb \
  db/migrate test/models test/rails_helper.rb
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
| Static asset routes (`/assets/css/*`, `/assets/turbo.js`, `/assets/vendor/fonts/*`) | Low individually | Better deferred until we set up the Rails asset pipeline (propshaft) — currently intentionally not configured. |

**Recommended next: open attack-order step 3** — *Auth Devise + omniauth Azure AD*.

Coexistence phase B has nothing left to port that is dynamic — every page, write, SSE and cookie route is Rails-native. The only thing still on the mounted Sinatra app is `/assets/*` (vendored Turbo JS, CSS files under `lib/autodev/web/public/css/`, woff2 fonts). Those are read-only static files; leaving them on Sinatra blocks nothing and they will move to propshaft as part of attack-order step 8 (Phlex view port + asset pipeline).

Step 2's purely-additive half landed: the 4 new AR tables + models + 20 tests are in. The remaining half (Issue/ActivityEvent Sequel→AR) still waits for phase C because of the `Object.const_set` collision (see [§4](#4-decisions-and-gotchas-that-bit-us)).

Attack-order steps that remain:

- **Step 3 — Devise + omniauth Azure AD** *(recommended next)*: `gem 'devise'`, `gem 'omniauth-microsoft_graph'` (or the Azure-AD-flavored variant). Step 2's `users.microsoft_uid` column is already in place to host the Azure subject claim. Devise mounted under `/users/...`, sessions table created. Phase B-compatible: doesn't require the poller to know anything new, only adds auth gates on Rails-native routes (existing Sinatra routes stay localhost-only as before).
- **Step 4 — rake YAML→DB import** : `autodev:migrate_projects_from_yaml` (autospec §H). Depends on step 2 tables (done) — code can land now, but the rake itself should not be executed until phase C, when the poller starts reading from DB.
- **Step 5 — Solid Queue** : `gem 'solid_queue'`, port `lib/autodev/poller.rb` logic to `AutodevPollJob` (recurring). The post-completion / unassignment / reentry branches all become job code. Coexistence phase C cutover.
- **Step 6 — `bin/autodev` superviseur** : boots `rails server` + `solid_queue:start` + sidecars (Chrome MCP). `lib/autodev/web/` deleted. `bundler/inline` already gone (`452d6e4`). Coexistence phase C cutover.

Steps 3, 4, 5 can land in any order — no inter-step dependency beyond the tables that step 2 just added. Step 6 (supervisor) is the actual coexistence phase C cutover and should be last among 3-6.

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

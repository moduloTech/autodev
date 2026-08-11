# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A Rails 8.1.3 application distributed as a CLI tool via Homebrew (`modulotech/tap`) that automates the implementation of GitLab issues. It polls configured projects for issues assigned to the autodev user with a `label_todo`, clones the repo, implements changes via `danger-claude`, commits, pushes, creates a Merge Request, waits for a green pipeline, then runs `mr-review` for automated code review.

`bin/autodev` is a supervisor: it boots Rails + the Solid Queue worker as child processes. `bin/rails server` serves the embedded dashboard; `bin/jobs start` runs `SolidQueue::Cli` which forks dispatcher + scheduler + worker subprocesses. The recurring `AutodevPollJob` fires every `poll_interval` seconds, discovers work via `Autodev::PollDispatcher`, and enqueues per-issue `IssueProcessJob`s that run the workflow classes (`IssueProcessor`, `MrFixer`, `PipelineMonitor`).

History: this used to be a single-file `bundler/inline` Sinatra+Sequel CLI. The migration to Rails (steps 1-8 of `docs/autospec.md` §C) wrapped 2026-06-09 with `v1.0.0-alpha.1`. See [`docs/railsification-postmortem.md`](docs/railsification-postmortem.md) for the retrospective. Phase D (AutoSpec — autospec.md §A, §E-G) is the next major feature scope; it is greenfield, not migration work.

## Running

```bash
# Production: brew install + service
brew install modulotech/tap/autodev
brew services start autodev

# Foreground from the supervisor (logs to stdout/stderr instead of ~/.autodev/log/)
autodev

# Custom config file
autodev -c path/to/config.yml

# CLI commands that read/mutate the SQLite file and exit (no supervisor):
autodev --status
autodev --errors [IID]
autodev --reset [IID]

# One-shot poll cycle (the old `--once` flag is gone — use the runner):
bin/rails runner 'AutodevPollJob.perform_now'
```

Dependencies are installed by `bundle install --deployment` at Brew install time. The wrapper at `/opt/homebrew/bin/autodev` pins Brew's Ruby on PATH (any `mise`/`rbenv`/`asdf` shim would otherwise pick a Ruby incompatible with the gems' native extensions).

Requires: Ruby ≥3.2, `danger-claude` on PATH (Brew dep), and optionally `mr-review` (Brew dep, automated review skipped if missing). When `app.run` ports are configured, Docker Desktop is also required for Chrome MCP injection.

## Local development

The repo runs the exact same code path as production — same Devise + Entra ID SSO, same `GitlabMembershipSync` in the OAuth callback, same Solid Queue worker. There is no dev-only auth bypass: you sign in with your real Microsoft 365 account and the callback resolves your real GitLab membership. To wire that up locally:

1. **`RAILS_ENV=development`**. `config/recurring.yml`'s `development:` block is empty, so the Solid Queue scheduler boots with zero recurring tasks — a local `bin/autodev` never auto-polls production tickets. Trigger a cycle by hand: `bin/rails runner 'AutodevPollJob.perform_now'`. `bin/autodev` prints a banner at boot reminding you of this.

2. **Azure SSO credentials**. Add an `azure:` block to your local `~/.autodev/config.yml` (mirrors prod's — same client_id / client_secret / tenant_id):
   ```yaml
   azure:
     client_id: <prod-client-id>
     client_secret: <prod-secret>
     tenant_id: <prod-tenant>
   ```
   Or export `AZURE_AD_CLIENT_ID` / `AZURE_AD_CLIENT_SECRET` / `AZURE_AD_TENANT_ID` (the supervisor forwards them to the Rails + worker children). Without one of those, `config/initializers/devise.rb` falls back to `stub-client-id` and Microsoft returns AADSTS700016. `bin/autodev` warns at boot when the stub is detected; the `/sign_in` page also surfaces a banner with the setup steps.

3. **Localhost redirect URI**. Register `http://localhost:4567/users/auth/entra_id/callback` (Web platform, not SPA) on the app in the Azure portal. The Entra ID strategy does server-side OAuth, so it needs a Web redirect — and Azure allows `http://localhost` specifically as an exception to the HTTPS-only rule for public clients.

4. **GitLab token**. Set `gitlab_token` in `~/.autodev/config.yml` (or `GITLAB_API_TOKEN` env var) to a real PAT with `api` scope. `Users::OmniauthCallbacksController#entra_id` calls `Autodev::GitlabMembershipSync.for_user!` synchronously on every login — without a working token the first sign-in raises `SyncFailed` and rolls back the new User row. Same scope as prod's token.

5. **Projects table populated**. Projects live in the DB (task #9). Add them from the dashboard (**Projets → Nouveau projet**, admin-only) once you can sign in, or seed from YAML by copying the `projects:` block from your prod `~/.autodev/config.yml` and running `bin/rails autodev:migrate_projects_from_yaml`. Without at least one project row the table is empty; `GitlabMembershipSync` will then compute zero memberships for your user, mark you `disabled`, and Devise will refuse the sign-in (401) — chicken-and-egg, so for a fresh local DB seed via the rake first. The sync logs `[gitlab_sync] WARNING: projects table is empty…` when this happens — that's the symptom.

6. **Boot the dev server**. `RAILS_ENV=development bin/autodev` runs the full supervisor (Rails + Solid Queue), or `RAILS_ENV=development bin/rails server -p 4567` if you only need the web UI and will trigger jobs by hand.

The first dev sign-in inserts your `users` row, runs the GitLab sync, and lands you on the dashboard with your prod memberships visible — exactly the prod flow. Re-running the sync after manual edits to `project_memberships` in dev: `bin/rails runner 'SyncGitlabMembershipsJob.perform_now'`.

## Configuration

Settings are resolved in 4 layers (highest priority wins):

1. **Defaults** — `poll_interval: 300`, `max_workers: 3`, `pickup_delay: 600`, `stagnation_threshold: 5`
2. **Config file** — `~/.autodev/config.yml`
3. **Environment variables** — `GITLAB_API_TOKEN`, `GITLAB_URL`, plus `AUTODEV_HOME` (default `~/.autodev`), `AUTODEV_DB`, `AUTODEV_QUEUE_DB`, `AUTODEV_MAX_WORKERS`, `AUTODEV_POLL_INTERVAL`
4. **CLI flags** — `-c`, `-d`, `-t`, `-n`, `-i`

### CLI flags

- `-c` / `--config PATH` — Config file path
- `-t` / `--token TOKEN` — GitLab API token
- `-n` / `--max-workers N` — Solid Queue worker threads (forwarded as `AUTODEV_MAX_WORKERS`)
- `-i` / `--interval SECONDS` — Poll interval (forwarded as `AUTODEV_POLL_INTERVAL`; rounded up to the nearest minute for cron)
- `--status` — Show dashboard of tracked issues and exit
- `--all` — Include completed (`done`) issues in `--status`
- `--errors [IID]` — Show details for errored issues (all or specific)
- `--reset [IID]` — Reset errored issues to pending (all or specific)
- `-v` / `--version` — Show version and exit
- `-h` / `--help` — Show help

(`--once` and `--dry-run` were retired at v1.0.0-alpha.1.)

### State on disk

Everything under `~/.autodev/` (override the root via `AUTODEV_HOME`):

| Path | Purpose |
|---|---|
| `~/.autodev/config.yml` | Projects + GitLab credentials |
| `~/.autodev/autodev.db` | Primary AR SQLite — issues, activity_events, users, projects, etc. |
| `~/.autodev/autodev_queue.db` | Solid Queue tables |
| `~/.autodev/secret_key_base` | Devise + session secret (generated on first boot, 0600) |
| `~/.autodev/log/production.log` | Rails log |
| `~/.autodev/log/autodev-{stdout,stderr}.log` | launchd-captured supervisor output |
| `~/.autodev/tmp/` | Rails tmp |

### Web UI

`bin/rails server` (spawned by the supervisor) exposes the dashboard at `http://<web.bind>:<web.port>` (default `127.0.0.1:4567`). It mirrors the data the CLI flags print (`--status`, `--errors`, `--reset`) but live-updates as transitions and activity events fire.

Routes (declared in `config/routes.rb`, all served by Rails controllers):
- `GET /` → `DashboardController#show` — status counters, active issues, KPI cards, sparkline, project breakdown.
- `GET /issues/:id` / `.json` → `IssuesController#show` — detail view (HTML or raw JSON).
- `GET /issues` → `IssuesController#index` — paginated + filterable list.
- `GET /errors` → `ErrorsController#index` — `error` + `needs_clarification` + non-null `post_completion_error`, with reset buttons.
- `GET /projects` → `ProjectsController#index` — union of YAML-configured + tracked projects.
- `GET /projects/new` + `POST /projects` → `ProjectsController#new`/`#create` — admin-only project creation in the DB (task #9 phase 4).
- `GET /projects/:slug` → `ProjectsController#show` — project's config (DB row via `Project#to_project_config`, YAML fallback) + 100 most recent issues. Slug encoding: `group/project` ↔ `group__project`.
- `GET /projects/:slug/edit` + `PATCH /projects/:slug` → `ProjectsController#edit`/`#update` — per-project config edit form, gated on project membership/admin (task #9 phase 3).
- `POST /issues/:id/reset` / `transition` / `close` — write actions.
- `GET /stream` → `StreamController#show` — SSE feed via `ActionController::Live`. Emits Turbo Stream HTML for each `activity_events` row.
- `GET /assets/css/*`, `/assets/turbo.js`, `/assets/vendor/fonts/*` → `AssetsController` — `send_file` from `app/assets/static/`.
- `GET /users/auth/entra_id` (+ callback) — Devise OmniAuth (Microsoft 365 SSO).

Implementation:
- Controllers live under `app/controllers/`. Each one `include ::Web::Helpers` to gain access to `app_config`, `dashboard_kpis`, `project_overview_stats`, etc.
- Phlex views live under `app/components/web/views/**/*.rb` (autoloaded via `config.autoload_paths << app/components`). Constant names are `Web::Views::Dashboard`, `Web::Views::Components::StatusPill`, etc.
- Helpers live under `app/helpers/web/{helpers,i18n_helpers,issues_filter,turbo_stream_helpers}.rb`.
- `Web::EventBus` (`app/services/web/event_bus.rb`) is an in-process pub/sub (Mutex around `Array<Queue>`). `ActivityEvent.after_create_commit` publishes; `/stream` subscribes. Backpressure drops events past 100.
- `Web::config` accessor (`app/services/web.rb`) holds the loaded `~/.autodev/config.yml` hash; populated by `config/initializers/load_autodev_config.rb` on Rails boot.
- Persistence: every AASM transition + every `ActivityLogger.post` writes an `activity_events` row (`kind: 'transition'` or `'danger_claude'`). Hooks live in `Issue#emit_activity_event!` (AR) and `ActivityLogger.persist_event!`, both wrapped in `rescue StandardError`.
- Localhost only by default (`web.bind: 127.0.0.1`). Expose via reverse proxy / NetBird if needed; autodev itself stays plain HTTP, no built-in auth gate on the dashboard (Devise is wired for AutoSpec — phase D — but no `before_action :authenticate_user!` is applied to the existing routes).
- Localized: views use `t_web(key, **vars)` → `Locales.t(key, locale: ...)`. Strings live in `config/locales/{notifications,activity,web}.{fr,en}.yml`. Locale comes from `web.locale` (default `fr`).

### App Environment (`app:`)

Per-project `app:` block provides structured environment instructions injected into all danger-claude prompts (priority over CLAUDE.md and skills). All subsections are optional.

```yaml
app:
  setup:                          # dependency installation
    - ["bundle", "install"]
    - ["yarn", "install"]
  test:                           # test commands
    - ["bin/test"]
  lint:                           # lint / auto-fix
    - ["bundle", "exec", "rubocop", "-A"]
  run:                            # background servers
    - command: ["bin/rails", "s"]
      port: 3000                  # exposed to host for Chrome access
    - command: ["bin/vite", "dev"]  # no port = not exposed
```

When any project has `app.run` entries with ports, Chrome DevTools is auto-enabled at supervisor startup (Chrome headless + MCP injection via Docker). No separate flag needed.

### Screenshot Workflow

When `app.run` is configured with ports, prompts instruct Claude to:
1. Launch background servers after implementation
2. Navigate impacted pages via Chrome DevTools MCP
3. Save PNG screenshots + `index.json` manifest in `/tmp/autodev_screenshots_<project>_<iid>/`

After danger-claude returns, `ScreenshotUploader` reads the manifest, uploads each PNG to GitLab (`client.upload_file`), and posts a formatted comment on the issue. Screenshots from MR discussion fixes are annotated with *(correction suite a review)*.

Screenshot instructions are injected in implementer and MR fixer prompts only (not pipeline fixer).

## Architecture

### Process topology

```
bin/autodev (supervisor parent)
├── bin/rails server   → Puma → Rails dashboard
└── bin/jobs start     → SolidQueue::Cli → forks:
    ├── solid-queue-dispatcher  (claims scheduled jobs)
    ├── solid-queue-worker × N  (perform AutodevPollJob, IssueProcessJob)
    └── solid-queue-scheduler   (fires config/recurring.yml entries)
```

`lib/autodev/supervisor.rb` owns the parent. SIGINT/SIGTERM trap → flag → `wait_loop` exits → TERM all children, 10s graceful grace, KILL stragglers. If any child crashes the supervisor tears the rest down.

### State Machine (AASM)

The `Issue` model (`app/models/issue.rb`) mounts AASM via `include AASM`. State machine logic lives directly in the AR model — the legacy `IssueBehavior` module was inlined during step 2 second half.

**States (16):** `pending`, `cloning`, `checking_spec`, `implementing`, `committing`, `pushing`, `creating_mr`, `reviewing`, `checking_pipeline`, `fixing_discussions`, `fixing_pipeline`, `running_post_completion`, `answering_question`, `needs_clarification`, `done`, `error`

`after_all_transitions :persist_status_change!, :emit_activity_event!` writes the row + emits an `activity_events` row on every transition.

### IssueProcessor

Handles the sequential flow from `pending` through `checking_pipeline`:
`start_processing!` → clone → `clone_complete!` → check spec → `spec_clear!` → implement → `impl_complete!` → commit → `commit_complete!` → push → `push_complete!` → create MR → `mr_created!` → `checking_pipeline`

For question/investigation tickets (no code changes needed): `question_detected!` → investigate codebase → post answer → `question_answered!` → `done`.

### MrFixer

Handles `fixing_discussions`: clones the MR branch, fetches unresolved discussions, fixes each one via `danger-claude -p` + `-c`, resolves discussions, pushes. Includes discussion stagnation detection. Fires `discussions_fixed!` → `checking_pipeline`.

### PipelineMonitor

Handles `checking_pipeline`: fetches MR head pipeline via GitLab API.

- **Running** → skip
- **Green + review_count == 0** → `reviewing` (launch `mr-review`), then `review_done!` → `checking_pipeline`. Review count incremented only on successful mr-review.
- **Green + review_count > 0 + no discussions** → `done`
- **Green + review_count > 0 + discussions** → `fixing_discussions`
- **Green + review_count >= MAX_REVIEW_ROUNDS (3)** → `done` with alert
- **Red (code)** → `pipeline_failed_code!` → `fixing_pipeline` → `pipeline_fix_done!` (with stagnation detection)
- **Red (infra/uncertain, first time)** → retrigger once, recheck next poll
- **Red (infra, after retrigger)** → stay in `checking_pipeline`, but track the failure signature; once the same infra job set recurs `stagnation_threshold` times, bail via `handle_stagnation` → `done` + `needs_attention` (`stagnation_pipeline`), so a never-recovering infra/deploy job can't poll forever
- **Manual/skipped** → verdict taken on the **blocking jobs** instead of the roll-up status (`allow_failure: true` jobs and unplayed `manual` gates excluded): no blocking job `failed` → `handle_green`, one or more failed → `handle_red`. `manual` is the normal end state of a green MR on any project whose pipeline ends with a manual `deploy_review`, so treating it as "wait" waited forever (Autodev #51). A GitLab error fetching the jobs leaves the row untouched for the next cycle — never read as green
- **Canceled** → stay in `checking_pipeline` (manual intervention needed)

Pipeline fix strategy: full job logs are written to `tmp/ci_logs/<job_name>.log` files in the work directory (no truncation). Prompts reference these files by path so danger-claude reads the complete log. Each failed job is fixed in a separate danger-claude call + commit (same pattern as MrFixer's per-discussion approach).

### PollDispatcher + IssueProcessJob

`app/services/autodev/poll_dispatcher.rb` runs one polling cycle per call: discovers issues from GitLab + DB, enqueues an `IssueProcessJob(project_path, issue_iid, action)` per work item. Eight dispatch passes per project:

- `dispatch_new_issues` — new `label_todo` issues → `:process`
- `dispatch_pipelines` — `checking_pipeline` rows → `:check_pipeline`
- `dispatch_discussions` — `fixing_discussions` rows → `:fix_discussions`
- `dispatch_unassignment` — active rows closed on GitLab or no longer assigned → closed / done inline (no job)
- `dispatch_done_unassigned` — `done` rows with `post_completion` configured → `:post_completion`
- `dispatch_dormant_audit` — rows that stopped moving (orphaned `pending`, spent-budget `error`, worker-pruned active states) → closed / done / re-armed inline, at most `dormant_audit_max` times per row
- `dispatch_retries` — `error` + `pending` with backoff elapsed → `:retry_errored` / `:retry_stuck`
- `dispatch_infra_recheck` — `done` + `stagnation_pipeline` rows → `:recheck_infra`

`app/jobs/issue_process_job.rb` is a single ActiveJob class that dispatches on the action symbol to the right worker class. `limits_concurrency to: 1, key: "issue-#{project}-#{iid}"` serializes work per ticket; the queue.yml `threads` setting (`AUTODEV_MAX_WORKERS`, default 3) caps global concurrency.

`app/jobs/autodev_poll_job.rb` is the recurring entry (`config/recurring.yml`, default `*/5 * * * *`). Gates on `UsageChecker#available?` so a Claude usage exhaustion pauses the polling instead of burning retries.

Both jobs wrap the ActiveJob `logger` in `Autodev::JobLogger` (`app/services/autodev/job_logger.rb`) before handing it to workflow classes — the legacy `AppLogger` accepted `info/warn/error(msg, project: path)` kwargs that Rails' `Logger` rejects.

## SQLite Schema

Two SQLite files:
- `~/.autodev/autodev.db` (primary): `issues`, `activity_events`, `users`, `projects`, `project_app_commands`, `project_memberships`, `sessions`, `schema_migrations`, `ar_internal_metadata`.
- `~/.autodev/autodev_queue.db` (queue): 10 Solid Queue tables.

AR migrations live under `db/migrate/` (primary) and `db/queue_migrate/` (queue). `config/initializers/auto_migrate.rb` runs both on Rails boot — idempotent, every `create_table` is `if_not_exists: true`. The same migration handles fresh installs and upgrades from the pre-rails Sequel-created prod DB.

**Who migrates, and what happens when it fails (Autodev #55).** `bin/autodev` requires `config/environment` before it reaches `run_supervisor`, so the **parent plays the pass first and alone**; the two children then boot their own Rails apps and play it again, which is a no-op in the normal case and the safety net for a child restarted on its own. SQLite reports `supports_advisory_locks? == false`, so Rails does not serialise two migrators: the loser of a boot race fails on `duplicate column name` or on the UNIQUE insert into `schema_migrations`, harmlessly, because the winner created the column. `Autodev::MigrationStatus` (`lib/autodev/migration_status.rb`) separates that case from a real failure:

- **the initializer never raises** — it logs a `warn` for a recognised race and an `error` otherwise, naming what is unapplied. It sits on the boot path of `bin/rails runner`, of `autodev --status` / `--errors` / `--reset`, of a standalone `bin/rails server` and of the test suite, all of which must keep booting;
- **`bin/autodev` refuses to start** when the pass left anything unapplied (`ConfigError` → exit 1, before any child is spawned). The predicate is a set difference between the migration files and `schema_migrations`, not an interpretation of the exception, so a benign race cannot trip it. The supervisor is the only entry point that refuses, because it is the one that starts the workers — a worker on an incomplete schema raises `NoMethodError` in `Project#to_project_config` on every job;
- **`/admin/health` carries a `migrations` card** (`down`, so `/healthz` answers 503) for the entry points that do boot.

Issue lifecycle (AASM):

```
pending → cloning → checking_spec → implementing → committing → pushing → creating_mr → checking_pipeline
               |          |              |                                                      |
          (closed)        |         (no changes)                                     ┌──────────┼──────────┐
               ↓          ↓              ↓                                           |          |          |
             done   needs_clarification  error                                  (green)     (red,      (running/
                          ↓                                                       |          code)    canceled/infra)
                       pending                                                    ↓          |          |
                                                                             reviewing   fixing_     skip
                    answering_question → done                                (mr-review)  pipeline      |
                                                                              |    |        |       (stays in
                                                                         (success)(crash)   ↓       checking_pipeline)
                                                                              |      |  checking_pipeline
                                                                              ↓      ↓
                                                                          checking_pipeline
                                                                          (review_count incr.
                                                                           only on success)
                                                                              |
                                                                   review_count > 0,
                                                                   pipeline green:
                                                                              |
                                                                  ┌───────────┴───────────┐
                                                                  |                       |
                                                             (no discuss)           (has discuss)
                                                                  |                       |
                                                                  ↓                       ↓
                                                                done            fixing_discussions
                                                                                          |
                                                                                          ↓
                                                                                   checking_pipeline

                                                           review_count >= 3:
                                                                  → done (with alert comment)

done + label_todo detected at poll → pending (reentry)
done + unassigned at poll → running_post_completion → done (if post_completion configured + MR not merged)
error (from any active state) → pending (on retry, with backoff)
needs_clarification (from checking_spec) → pending (when clarification comment posted)
```

## Error Handling

| Case | Behaviour |
|------|-----------|
| `danger-claude` not installed | Abort at startup |
| `mr-review` not installed | Warning at startup, review step skipped |
| Clone fails | `mark_failed!` → error, next issue |
| No changes produced | `mark_failed!` → error |
| Push fails | Retry with --force-with-lease |
| MR already exists for branch | Reuse existing MR |
| Issue closed between poll and processing | `clone_complete!` → done (guard: issue_closed?) |
| Issues in error at startup | `Issue.recover_on_startup!` resets transient states |
| Interrupted pre-MR processing (`cloning`…`creating_mr`, no MR yet) | Reset to `pending` **and `next_retry_at` stamped** → re-enqueued via `:retry_stuck` next poll (without the stamp the GitLab label stays `label_doing`, so `dispatch_new_issues` never re-discovers it → orphaned `pending`) |
| Pipeline red (code by pre-triage) | Skip retrigger, go straight to fix phase |
| Pipeline red (infra/uncertain, first time) | Retrigger once, recheck next poll |
| Pipeline red (infra/uncertain, after retrigger) | Stay in checking_pipeline; if the same infra job set recurs `stagnation_threshold` times, bail via stagnation → done + needs_attention (`stagnation_pipeline`) |
| Pipeline manual / skipped | Resolved on the blocking jobs (`allow_failure: false`, not an unplayed manual gate): none failed → green → mr-review → done; one failed → the red path |
| Pipeline manual / skipped, jobs endpoint unreachable | Stay in checking_pipeline, recheck next poll (an API error must never read as "nothing failed") |
| Pipeline canceled | Stay in checking_pipeline (manual intervention) |
| Stagnation detected (pipeline or discussions) | Transition to done with alert comment |
| Review limit reached (3 rounds) | Transition to done with alert comment |
| Unassigned during implementation | Transition to done at next poll cycle |
| Interrupted fixing_pipeline | Reset to checking_pipeline on startup |
| Interrupted reviewing | Reset to checking_pipeline on startup |
| Post-completion command fails | Non-fatal: error stored in `post_completion_error`, issue still transitions to `done`, visible via `--errors` |
| Interrupted running_post_completion | Reset to `done` on startup (non-fatal, not re-executed) |
| Row dormant (`pending` with no `next_retry_at`, `error` with a spent budget, active state frozen 2h) | `dispatch_dormant_audit` gives it a bounded second look: closed on GitLab → `closed`, unassigned → `done`, still ours → re-armed. After `dormant_audit_max` fruitless rounds: `needs_attention` (`dormant_exhausted`) |
| Interrupted `fixing_discussions` / `answering_question` | Revived by `Issue.revive_stalled!` — at startup and, if the service does not restart, by the dormant audit |

## Key Design Decisions

- **Rails 8 monolith over single-file CLI**: The single-file `bundler/inline` pattern (still used by `danger-claude` and `mr-review`) stopped scaling once we needed background jobs, multi-DB, SSO, and structured background processing. Rails 8 + Solid Queue replaced ~2,000 LOC of bespoke threading/Sinatra/Sequel/poller with conventional Rails primitives. See `docs/railsification-postmortem.md` for the migration's full account.
- **AASM state machine**: Formalized transitions prevent invalid state changes. Guards handle conditional branching. `after_all_transitions :persist_status_change!, :emit_activity_event!` auto-saves and writes a row to `activity_events`.
- **Supervisor over single-process**: `bin/autodev` parent spawns `bin/rails server` + `bin/jobs start` instead of running an in-process Puma + thread pool. Each child boots its own Rails app; SQLite WAL + `busy_timeout` handles the two-writer contention.
- **Multi-DB (primary + queue)**: Solid Queue's 10 tables live in their own SQLite file so their CRUD churn doesn't share the WAL with business writes. AR's multi-database config (`config/database.yml`) handles the routing transparently.
- **Review after pipeline**: `mr-review` runs after the first green pipeline, not immediately after MR creation. This ensures the pipeline is stable before review comments are generated.
- **Stagnation detection**: Replaces `max_fix_rounds`. SHA256 signatures of failed job names (pipeline) or unresolved discussion IDs (discussions) detect when the same failures repeat consecutively. Configurable threshold (`stagnation_threshold`, default 5).
- **Polling by assignee**: Issues are discovered by querying GitLab for issues assigned to the autodev user with `labels_todo`, replacing the old `trigger_label`-based approach.
- **3 labels only**: `labels_todo`, `label_doing`, `label_done`. Label stays `label_doing` during the entire implementation + pipeline + fix + review cycle, and switches to `label_done` only when reaching `done`.
- **Post-completion at unassignment**: The `post_completion` hook triggers when autodev is unassigned from a `done` issue (not immediately after pipeline green).
- **No blocked state**: Canceled pipelines keep the issue in `checking_pipeline` indefinitely until manual intervention or natural resolution — an interrupted run has no verdict to read (its blocking jobs are `canceled`, not `failed`), and unlike a manual gate it is usually superseded by a new pipeline that `head_pipeline` re-points to. This deliberately **no longer covers `manual`/`skipped`** (Autodev #51): a manual `deploy_review` is the normal end of a green MR on some projects, so that wait was infinite by construction, and the blocking jobs answer the question the roll-up cannot. Infrastructure failures do the same *only until stagnation* — a recurring infra/deploy failure that never recovers is bailed out via `handle_stagnation` (→ `done` + `needs_attention`) after `stagnation_threshold` identical polls, so it can't loop forever.
- **danger-claude as implementation engine**: Leverages the existing Docker-based Claude CLI wrapper for sandboxed code generation.
- **Solid Queue concurrency control**: `IssueProcessJob`'s `limits_concurrency to: 1, key: "issue-#{path}-#{iid}"` ensures no two jobs touch the same issue at once. Global concurrency cap comes from `queue.yml`'s `threads` setting (`AUTODEV_MAX_WORKERS`, default 3) — mirrors the legacy `max_workers`.

## Localization (i18n)

**Rule: every user-facing string — CLI output, GitLab notes, web UI — must go through `Locales.t` / `t_web`. Never write a literal user-facing string in code or templates, in any language.**

Hardcoded literals are the source of every "why doesn't EN work?" bug we've already paid for once (`Dashboard.status_label` ignored the cookie until 51f0b0e).

### Where templates live

All under `config/locales/`:

| File | Purpose |
|---|---|
| `notifications.{fr,en}.yml` | One-off GitLab issue comments (errors, MR links, completion, stagnation, etc.) |
| `activity.{fr,en}.yml` | Per-issue activity-log entries (the single updated comment) |
| `web.{fr,en}.yml` | Every string rendered by the embedded web UI |
| `en.yml` | Rails default English (used by gems we depend on) |

Templates are loaded by Rails' i18n railtie. `Locales.t(key, locale:, **vars)` is a thin adapter around `I18n.t` with strict `:fr` fallback (`Locales` includes `I18n::Backend::Fallbacks`). Vocabulary follows `docs/autospec.md` §I — business-facing language, not technical step names.

### How to add a new string

1. Pick a key with the right prefix: `notify_*`, `activity_*`, `web_*`. Keep them flat (no nesting).
2. Add it to the matching `config/locales/<area>.{fr,en}.yml` files **in both `fr` and `en`**, with the same `%{var}` placeholders in each.
3. Use the right helper at the call site:
   - **Ruby code (CLI, processors, services)**: `Locales.t(:my_key, locale: <locale>, **vars)`. The `locale` argument is mandatory in this layer — pick from `issue.locale`, a config field, or default to `:fr`.
   - **Phlex views**: `t_web(:my_key, **vars)` (auto-escaped, no `h()` wrapper needed). `t_web` resolves the active locale automatically (cookie > config > default).
4. If the string represents a status label or any web concept derived from a Ruby value (not a literal in the template), wire it into `STATUS_LABEL_KEYS` in `app/helpers/web/i18n_helpers.rb` rather than inlining a `case`.

### Locale resolution per layer

| Layer | Source | Helper |
|---|---|---|
| Web UI | cookie `locale` > config `web.locale` > `:fr` | `Web::I18nHelpers#web_locale` + `t_web` |
| GitLab activity log / notifications | `issue.locale` column (per-issue, set on creation, default `:fr`) | `Locales.t(..., locale: issue.locale.to_sym)` |
| CLI dashboard / `--status` / `--errors` | `:fr` for now (no flag) | `Locales.t(..., locale: :fr)` — still go through it so adding `--locale en` later is a one-line change |

### What NOT to do

- Hardcode user-visible literals in Phlex views. The only allowed bare strings are pure structural markup, code/paths/URLs, punctuation, and technical tokens that aren't translated (e.g. AASM state names, `JSON`, `MR`).
- Translate FR but skip EN (or vice versa). Both keys must exist or `Locales.t` falls back silently and you get mixed-language output.
- Add a new helper that returns French verbatim (e.g. `def label_for_X; 'Terminée'; end`). If the helper produces text shown to a user, it must take a locale and call `Locales.t`.

## Tests

`bundle exec rake test` runs the full minitest suite. `test/test_helper.rb` boots the Rails environment in `RAILS_ENV=test` (in-memory SQLite for both primary + queue) and force-loads the AR models so tests that don't transitively reference them through `Issue` still see them defined. ~452 tests at v1.0.0-alpha.3.

`test/database_test_helper.rb` re-runs the migrations idempotently and wipes `issues` + `activity_events` between tests (`:memory:` SQLite drops the schema on every reconnect; the migration's `if_not_exists: true` makes the re-run a no-op once tables exist).

Job tests under `test/jobs/` use `Autodev::JobLogger` mocks; they don't require the full legacy stack.

## Phase D (AutoSpec) — next major scope

The railsification is done. The next chunk of work is autospec.md §C steps 9-12: `autospec_*` backend tables, `AutospecChat` service around the Anthropic SDK, frontend port of `reference/screen-chat-spec.jsx`, workflow approbation via `project_memberships`, GitLab ticket import. Greenfield, no migration risk. See `docs/autospec.md` §A, §E, §F, §G for the spec.

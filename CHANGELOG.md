# Changelog

## [Unreleased]

### Added

- Chrome DevTools MCP support: new `chrome_devtools` config option launches headless Chrome with remote debugging and injects the MCP server config, proxy, and skill into danger-claude containers.
- `ChromeLauncher` module: detects/launches Chrome with `--remote-debugging-port=9222 --headless=new`.
- `ChromeDevtoolsInjector` module: injects `mcpServers.chrome-devtools` into the Docker volume's `.claude.json` and provides bind-mount args for proxy scripts and skill.

## [0.8.5] - 2026-04-07

### Fixed

- Fix `CLEAN_ENV` constant resolution in `PostCompletion` module — fully qualify as `DangerClaudeRunner::CLEAN_ENV`.

## [0.8.4] - 2026-04-07

### Fixed

- Fix `PostCompletion#run_with_timeout` shadowing `ProcessRunner#run_with_timeout`, causing `ArgumentError: wrong number of arguments (given 3, expected 5)` when PipelineMonitor runs danger-claude during pipeline fixes.

## [0.8.3] - 2026-04-03

### Fixed

- Fix label workflow routing: issues in `pending` state with `label_mr` are now correctly routed to processing instead of being silently skipped. Previously, only `label_todo` triggered processing for pending issues.

## [0.8.2] - 2026-04-03

### Fixed

- Fix issues with existing MRs reset to `pending` on startup recovery: `recover_stuck_processing!` now resumes at `checking_pipeline` when the issue already has a MR, matching the behaviour of `recover_errored!`.

## [0.8.1] - 2026-04-03

### Added

- Comprehensive config validation (`Config.validate!`) at startup: validates global numeric fields are positive integers, `log_level` is a valid level, `gitlab_token` is present, and per-project fields (`path` required, `post_completion` must be array of strings, `post_completion_timeout` requires `post_completion`, `clone_depth` non-negative, `sparse_checkout` array of strings).
- Localized GitLab issue comments: language is auto-detected from the issue body (French/English heuristic via function-word frequency) and stored in a `locale` column. All 14 `notify_issue` calls now use locale-aware templates (`Locales.t`).
- JSON Lines structured log files (`.jsonl`): log files now emit one JSON object per line with `timestamp`, `level`, `project`, `issue_iid`, `state`, `event`, `message`, and `context` fields for LLM consumption. Console output remains human-readable with colors.
- Minitest test suite with 278 tests covering state machine transitions and guards, startup recovery, pipeline pre-triage classification, config validation, language detection, locales, logger JSON output, and error classes.

### Changed

- Refactor all modules to fix Metrics RuboCop offenses: extract `LabelManager`, `IssueNotifier`, and `ProcessRunner` from `DangerClaudeRunner`; decompose `IssueProcessor`, `PipelineMonitor`, `MrFixer`, `SkillsInjector`, `GitlabHelpers`, `Config`, `Database`, and `bin/autodev` into focused sub-modules.
- Hoist GitLab client and `MrFixer` helper instantiation above the error retry loop so they are reused across retried issues in the same poll tick instead of being recreated per issue.
- Deduplicate error retry branches: the MR vs non-MR paths now share a single code path that selects the transition method, label, and log target based on `mr_iid` presence.

### Fixed

- Write context files to `/tmp` instead of the git work tree so they cannot be accidentally committed by danger-claude. Mount `/tmp` into the container via `-v /tmp`.
- Use process groups (`pgroup: true`) for subprocess spawning so that timeout kills (`TERM`/`KILL`) reach the entire process tree, not just the direct child. Prevents orphaned grandchild processes (e.g., Docker containers) from lingering after a timeout.
- Fix `NoMethodError: private method 'cleanup_labels' called for an instance of MrFixer` when polling detects a done label.
- Fix issues stuck on `label_doing` after error retry: restore `labels_todo` on retry so the polling loop picks them up correctly.
- Fix issues with existing MRs restarting from scratch after error retry: resume at `checking_pipeline` instead of `pending`.

## [0.8.0] - 2026-04-02

### Added

- **Label-driven workflow**: new per-project config fields `labels_todo` (array), `label_doing`, `label_mr`, `label_done`, `label_blocked` replace `labels_to_remove`/`label_to_add` with a full lifecycle. Labels are set/removed at each state transition: `labels_todo` → `label_doing` (processing) → `label_mr` (MR created, discussion monitoring) → `label_done` (set by reviewer, triggers cleanup). `label_blocked` is set on infra failures or max fix rounds.
- **Resume from over**: issues in `over` state can be re-activated via labels. Adding a `labels_todo` label triggers full re-processing (spec check → implement → MR). Leaving `label_mr` with unresolved MR discussions triggers automatic discussion fix. New AASM events: `resume_todo!` (over → pending), `resume_mr!` (over → fixing_discussions).
- **Context file**: issue context (title, body, comments) and all MR discussions (resolved + unresolved) are written to a single markdown file at the clone root (named after the branch, e.g. `123-fix-login.md`). All prompts reference this file instead of embedding context inline. File is deleted after each danger-claude call.
- Per-project `post_completion` hook: configurable command (Docker CMD format, e.g. `["./bin/deploy", "--env", "staging"]`) executed after pipeline green and discussions resolved, just before `over`. New `running_post_completion` state. Non-fatal — errors are logged and visible in `--errors`. Environment variables `AUTODEV_ISSUE_IID`, `AUTODEV_MR_IID`, `AUTODEV_BRANCH_NAME` available. Timeout configurable via `post_completion_timeout` (default 300s).
- Issue assignment management: autodev assigns itself to the issue when starting work, then reassigns the issue author when reaching `over` (question answered or pipeline green).
- New `code-conventions` skill injected into all projects: language-agnostic rules for code comments (WHAT/WHY/HOW) and commit messages (Conventional Commits). Previously these rules were embedded in the Rails-specific skill and ignored for JS/other languages.
- All prompts (implementation, MR fix, pipeline fix) now explicitly list the skills to load (e.g. `code-conventions`, `rails-conventions`, etc.) before starting work.
- `--version` / `-v` CLI flag to display the current version.
- Version tag now appears in every GitLab comment (e.g. `:robot: **autodev** (v0.7.0) : traitement en cours...`).

### Changed

- **`needs_clarification`** now sets the first `labels_todo` label (removing `label_doing`), enabling re-processing when a human responds.
- **`question_answered`** now removes `label_doing` without adding any label back — the human decides the next step by manually setting a label. This avoids an infinite loop where the question would be re-detected every poll cycle.
- **Crash recovery**: issues stuck in active processing states (`cloning`, `checking_spec`, `implementing`, etc.) are now reset to `pending` on startup. In label workflow, this means `label_doing` issues are recovered automatically.
- `rails-conventions` skill no longer contains Code Comments and Commit Messages sections — these are now in the language-agnostic `code-conventions` skill.

### Deprecated

- `labels_to_remove` and `label_to_add` project config fields. Still accepted but emit a deprecation warning to stderr. Use the new label workflow fields instead (`labels_todo`, `label_doing`, `label_mr`, `label_done`, `label_blocked`).

## [0.7.0] - 2026-03-31

### Added

- Question/investigation ticket handling: autodev now recognizes tickets that ask questions about existing behavior (not implementation requests), investigates the codebase, and posts an answer as a GitLab comment instead of attempting code changes. New state `answering_question` with events `question_detected` and `question_answered`.

### Changed

- Spec check now instructs Claude to resolve app URLs from tickets (e.g. `https://app.example.com/companies/test/drivers/history`) by looking up the route in `config/routes.rb`, reading the controller and view code, and using that context to self-answer questions before requesting clarification.
- `--errors` now includes blocked issues in addition to errored ones, with distinct color coding (yellow for blocked, red for error).
- New `model` and `effort` config keys (global and per-project) forwarded to `danger-claude` as `--model` and `--effort`. Project-level overrides global.
- `rails-conventions` skill now requires code comments in English covering WHAT, WHY, and HOW, and commit messages in English using Conventional Commits format (`<type>: <description>`) with a detailed body.
- Pipeline auto-retrigger is now conditional on pre-triage verdict. Previously, every pipeline failure was retriggered once before analysis. Now, only `:infra` and `:uncertain` verdicts trigger a retry — `:code` failures go straight to the fix phase, saving a full pipeline cycle.

### Fixed

- Worker pool now deduplicates enqueue calls: if an issue is already queued or being processed, subsequent enqueue attempts for the same `issue_iid` are silently skipped. Fixes a race condition where the polling loop could enqueue the same `fixing_discussions` task twice, causing a `git clone` failure when two workers tried to clone to the same temp directory.
- Image download errors now include the exception class and message (e.g. `SocketError`, `URI::InvalidURIError`) instead of a generic "download failed", making it possible to diagnose failures from logs.
- Skills are now injected as subdirectories with `SKILL.md` files (e.g. `.claude/skills/rails-conventions/SKILL.md`) instead of bare `.md` files. This matches the Claude Code skill format. Existing legacy `.md` skills are automatically migrated to the new format.
- Jobs with `allow_failure: true` are now excluded from pipeline failure analysis and fix attempts. These jobs don't block the pipeline and should not trigger retriggers or fixes.
- API rate limit errors ("You've hit your limit") no longer burn retry attempts. Rate limits are detected from danger-claude output and the issue is parked until the reset time without incrementing `retry_count`. Applies to all three processors (IssueProcessor, MrFixer, PipelineMonitor).
- Deploy jobs (deploy_review, etc.) no longer sent to danger-claude for fixing. Jobs matching deploy/release/provision/terraform/helm/k8s patterns are now classified as infra in pre-triage and skipped during pipeline fix. Previously, a deploy job with `script_failure` would be classified as code, causing a 30-minute timeout with no useful result.

## [0.6.3] - 2026-03-30

### Added

- `--status` now shows the worker assigned to each active issue (e.g. `[worker-3]`), matching the poll status summary. Worker assignments are persisted to `~/.autodev/workers.json` by the running instance.
- `--errors [IID]` shows error details (message, stderr) for issues in error state. Without IID, shows all; with IID, shows a specific issue.
- `--reset [IID]` resets errored issues to pending (retry_count zeroed). Without IID, resets all; with IID, resets a specific issue.

### Fixed

- Fix `datetime('now')` and `datetime('now', '+N seconds')` stored as literal strings instead of being evaluated by SQLite for `started_at`, `finished_at`, and `next_retry_at` fields. This broke automatic error retries since `next_retry_at` comparisons never matched. Same root cause as the `clarification_requested_at` fix in v0.6.0 — use dataset-level `Issue.where(id:).update()` instead of model-level `issue.update()` so `Sequel.lit()` expressions are passed through to SQLite.

## [0.6.2] - 2026-03-30

### Added

- Poll status summary: after each polling cycle, print a compact status of all active (non-over) issues to stdout with their state, project, and assigned worker. Not written to log files.

### Changed

- Dashboard (`--status`) now hides completed (`over`) issues by default. Use `--status --all` to show all issues.

### Fixed

- Fix branch checkout on shallow clones: fetch the remote branch before checkout when reusing an existing branch. Shallow clones (`--depth 1`) only fetch the target branch, so `git checkout autodev/...` would fail with "pathspec did not match". Uses explicit refspec to bypass `--single-branch` restriction.
- Fix `Could not process image` API error: validate downloaded images by checking Content-Type header before writing to disk. Non-image responses (HTML error pages, etc.) are replaced with a text placeholder instead of being passed to Claude.
- Fix Ctrl+C during danger-claude marking issues as errored: detect SIGINT on subprocess exit and re-raise `Interrupt` so the worker pool shuts down gracefully instead of treating it as an implementation failure.
- Fix garbled stdout when multiple workers run in parallel. Multiline messages (full prompts) are now truncated to the first line on the console; full content goes to log files only. Also close stdin on spawned subprocesses to prevent TTY inheritance.

## [0.6.1] - 2026-03-30

### Fixed

- Fix crash on transient network errors (DNS resolution, connection refused) during issue polling. The rescue clause caught only `AutodevError` instead of `StandardError`, letting `Socket::ResolutionError` and similar exceptions kill the process.

## [0.6.0] - 2026-03-30

### Added

- Dashboard: `autodev --status` displays a table of all tracked issues with their state, project, MR link, and contextual comments. Color-coded by status with a summary line.

### Fixed

- Fix clarification detection: compare timestamps as parsed `Time` objects instead of raw strings. SQLite's `datetime('now')` format and GitLab's ISO 8601 format were compared lexicographically, causing `needs_clarification` issues to never detect human replies.
- Fix `clarification_requested_at` stored as literal string `"datetime('now')"` instead of evaluated timestamp. `Sequel.lit()` is not interpreted by Sequel::Model#update — use dataset-level update instead.
- Fix GitLab image download failing with 302: follow HTTP redirects (up to 3 hops) when downloading issue attachments. GitLab redirects authenticated upload URLs, and `Net::HTTP` does not follow redirects automatically.

## [0.5.1] - 2026-03-27

### Fixed

- Add `logger` gem to inline Gemfile for Ruby 4.0 compatibility (`logger` was removed from default gems).
- Fix AASM + Sequel compatibility on Ruby 4.0: name the Issue class via `const_set` before `include AASM` so that AASM's `StateMachineStore` registers under the correct key (`"Issue"` instead of the anonymous class name).

## [0.5.0] - 2026-03-26

### Added

- Parallel agents mode: when `parallel_agents: true` is set in project config, autodev evaluates issue complexity via a Claude call. Simple issues fall back to single/split mode. Complex issues (multi-layer, multi-domain) are decomposed into a work plan of up to 4 tasks, each executed by a specialized agent in its own git worktree in parallel. Results are merged back. All-agents-failed is fatal; partial failures are tolerated. Disabled by default.
- Split implementation mode: when `split_implementation: true` is set in project config, the implementation step runs two specialized agents in parallel using git worktrees — an `implementer` (code only) and a `test-writer` (tests only, from spec). Each runs in its own working directory via `git worktree add`. Test files are merged back after both complete. Code errors are fatal; test-writer errors are non-fatal. Each agent is injected automatically if not present in the project. Default agents use model: sonnet. Disabled by default; single-pass mode unchanged.
- MR discussion fix: use project-level `mr-fixer` subagent when `.claude/agents/mr-fixer.md` exists in the target repo. The agent is passed to danger-claude via the new `-a` flag, enabling persistent memory that accumulates fix patterns across conversations. Configurable per-project via `mr_fixer_agent` in config.
- Pipeline pre-triage: classify pipeline failures using GitLab `failure_reason` before cloning or calling Claude. Infrastructure failures (`runner_system_failure`, `stuck_or_timeout_failure`, etc.) are blocked immediately — no clone, no tokens spent. Code failures (`script_failure`) skip the Claude evaluation call and go straight to fix. Only uncertain cases fall back to Claude evaluation.
- Pipeline fix categorization: classify failed jobs as test/lint/build by job name, stage, and log patterns. Fix prompts are tailored per category with specific guidance (e.g., "fix source code not tests" for test failures, "fix only flagged files" for lint).
- MR discussion fix: enrich context passed to danger-claude with issue title/description, MR description, exact line numbers, and the relevant diff hunk extracted via `git diff`. Eliminates the exploration turn Claude previously needed to locate the code.
- Skills injection: auto-detect project stack (Ruby version, Rails version, database, test framework) and inject default Claude Code skills (`rails-conventions`, `test-patterns`, `database-patterns`) into `.claude/skills/` of the cloned repo when the project doesn't provide its own. Skills are version-aware (Rails 4.x through 8.x) and DB-aware (PostgreSQL, MySQL). Existing skills are always preserved. Also detects Devise, Pundit, CanCanCan, Sidekiq, RuboCop, and API-only mode for targeted guidance.

## [0.4.0] - 2026-03-26

### Refactored

- Split single-file script into `lib/autodev/` modules: errors, logger, config, database, shell_helpers, gitlab_helpers, danger_claude_runner, issue_processor, mr_fixer, pipeline_monitor, worker_pool. Entry point `bin/autodev` reduced from ~2200 to 340 lines.
- Extract shared `DangerClaudeRunner` module: `run_with_timeout`, `danger_claude_prompt`, `danger_claude_commit`, `clone_and_checkout`, `notify_issue`, logging. Included by IssueProcessor, MrFixer, and PipelineMonitor, eliminating ~200 lines of duplication.
- Extract `ShellHelpers` and `GitlabHelpers` modules.

### Added

- AASM state machine: formalized all status transitions using the `aasm` gem with Sequel::Model. Each state corresponds to exactly one action. Events with guards enforce valid transitions. Issue model is built dynamically after DB connection (`Database.build_model!`).
- Pipeline monitoring: `checking_pipeline` state checks MR pipeline status each poll cycle. Green + no conversations → `over`, green + conversations → `fixing_discussions`, running → skip, red → retrigger once then evaluate via danger-claude.
- Pipeline code fix: code-related pipeline failures are fixed directly by PipelineMonitor (`fixing_pipeline` state). Full job logs are written to `tmp/ci_logs/` files in the work directory (no truncation) and referenced by path in prompts. Each failed job is fixed in a separate danger-claude call + commit.
- `blocked` status for issues requiring manual intervention (non-code pipeline failures, canceled/skipped pipelines).
- `checking_spec` state: specification clarity check is now a dedicated state (previously embedded in `implementing`).

### Changed

- **State machine rationalized**: eliminated pass-through states `done` and `mr_fixed`. `reviewing` transitions directly to `checking_pipeline`. `fixing_discussions`/`fixing_pipeline` transition directly to `checking_pipeline`.
- **Status renamed**: `mr_pipeline_running` → `checking_pipeline`, `mr_fixing` → `fixing_discussions`, `mr_pipeline_fixing` → `fixing_pipeline`. Automatic migration of existing DB records.
- Database module simplified: removed `update_issue`, `find_issue`, `insert_issue`, `issues_for_*`, `transition_to_pipeline_running!`, `mark_max_rounds_as_over!`. Replaced by Issue Sequel::Model with AASM events.
- `over` is the terminal success status, reached only when pipeline is green and no open conversations remain.

## [0.3.0] - 2026-03-24

### Added

- MR comment fixing: automatically fix unresolved MR discussions (from mr-review or humans). One discussion = one danger-claude call = one commit. Discussions are resolved after fixing. Status lifecycle: `done` → `mr_fixing` → `mr_fixed` → ... → `over`. Configurable `max_fix_rounds` (default: 3, per-project overridable). Only processes issues that still have the `autodev` trigger label.
- Random suffix in branch names (`autodev/{iid}-{slug}-{hex8}`) to allow re-processing the same issue. Reuses the existing branch from the database if it still exists on the remote; otherwise generates a new name.
- Download GitLab images from issue descriptions and comments into `.autodev-images/` in the workdir so Claude can see screenshots and diagrams during implementation.

### Changed

- Exclude autodev's own comments from the issue context passed to the implementation prompt.
- Log all danger-claude prompts at DEBUG level for troubleshooting.

### Fixed

- Shallow clone with `target_branch`: pass `--branch` to `git clone` so the target branch is fetched even with `--depth 1` (previously failed with "pathspec did not match").

## [0.2.0] - 2026-03-23

### Added

- Shallow clone by default (`--depth 1`) for faster cloning of large repos.
- Per-project `clone_depth` config option (0 for full clone, default: 1).
- Per-project `sparse_checkout` config option for monorepo support.
- Better branch slug generation using `i18n` transliteration (`incohérent` → `incoherent` instead of `incohrent`).
- `--dry-run` flag to poll and display which issues would be processed without side effects.
- Capture and store danger-claude stdout/stderr (`dc_stdout`, `dc_stderr` columns) from all calls (`-p` and `-c`) in the database for debugging and audit.
- Configurable danger-claude timeout (`dc_timeout`, default: 1800s/30min). Global or per-project. Uses `Process.spawn` with TERM/KILL for reliable subprocess cleanup.
- Structured logging with levels (DEBUG/INFO/WARN/ERROR), timestamps, dual output (stdout + file), daily log rotation. Global logs in `~/.autodev/logs/autodev/`, per-project logs in `~/.autodev/logs/{project}/`. Configurable via `log_dir` and `log_level` in config.
- Retry with exponential backoff and max retries per issue (`max_retries` default: 3, `retry_backoff` default: 30s). Global or per-project. Issues that exceed max retries are skipped. Backoff doubles each attempt (30s → 60s → 120s).
- Partial progress recovery: on retry, if the branch was already pushed, skip directly to MR creation instead of re-implementing from scratch.
- Issue notifications: post comments on GitLab issues when processing starts, succeeds (with MR link), or fails (with error summary).
- Specification check: before implementation, analyse the spec for ambiguities via a dedicated danger-claude call. If unclear, post a comment listing questions and mark as `needs_clarification`. On each poll, check for new human comments to automatically resume.

### Fixed

- Label guard: labels are now updated after MR creation succeeds, preventing issues from being left in a bad state if MR creation fails.

## [0.1.0] - 2026-03-23

### Added

- Automated GitLab issue implementation via danger-claude.
- Poll configured projects for issues with a trigger label (default: `autodev`).
- Clone repo, create branch, implement changes, commit, push, create MR automatically.
- GitLab label management: remove configured labels, add completion label.
- Optional headless mr-review on created MRs.
- SQLite persistence for issue tracking with status lifecycle.
- Concurrent worker pool (configurable, default 3 threads).
- 4-layer configuration: defaults, `~/.autodev/config.yml`, environment variables, CLI flags.
- Graceful shutdown on SIGINT/SIGTERM.
- Auto-retry of errored issues on restart.
- `--once` flag for single poll cycle.
- Auto-generation of CLAUDE.md for projects that lack one.

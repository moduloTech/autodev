# Changelog

## [Unreleased]

### Added

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

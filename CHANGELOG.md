# Changelog

## [Unreleased]

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

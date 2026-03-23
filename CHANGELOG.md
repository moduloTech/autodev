# Changelog

## [Unreleased]

### Added

- Shallow clone by default (`--depth 1`) for faster cloning of large repos.
- Per-project `clone_depth` config option (0 for full clone, default: 1).
- Per-project `sparse_checkout` config option for monorepo support.

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

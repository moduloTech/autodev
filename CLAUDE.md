# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A single-file Ruby CLI tool (`bin/autodev`) distributed via Homebrew (`modulotech/tap`) that automates the implementation of GitLab issues. It polls configured projects for issues with a trigger label, clones the repo, implements changes via `danger-claude`, commits, pushes, manages labels, creates a Merge Request, and optionally runs `mr-review` in headless mode.

## Running

```bash
# Poll with default config
./bin/autodev

# Single poll cycle
./bin/autodev --once

# Custom config
./bin/autodev -c path/to/config.yml

# Override token and workers
./bin/autodev -t glpat-xxxx -n 5
```

Dependencies are installed automatically via `bundler/inline` (no separate `bundle install` needed). Requires Ruby, `danger-claude` on PATH, and optionally `mr-review` for automated reviews.

## Configuration

Settings are resolved in 4 layers (highest priority wins):

1. **Defaults** — `trigger_label: "autodev"`, `poll_interval: 300`, `max_workers: 3`
2. **Config file** — `~/.autodev/config.yml`
3. **Environment variables** — `GITLAB_API_TOKEN`, `GITLAB_URL`
4. **CLI flags** — `-c`, `-d`, `-t`, `-n`, `-i`, `--once`

### CLI flags

- `-c` / `--config PATH` — Config file path
- `-d` / `--database-url URL` — SQLite connection URL
- `-t` / `--token TOKEN` — GitLab API token
- `-n` / `--max-workers N` — Concurrent workers
- `-i` / `--interval SECONDS` — Poll interval
- `--once` — Single poll cycle then exit
- `-h` / `--help` — Show help

## Architecture

### State Machine (AASM)

The Issue model uses the `aasm` gem for a formalized state machine. Each state = one action. Events define valid transitions with guards.

The Issue Sequel::Model is built dynamically after DB connection via `Database.build_model!`.

### IssueProcessor

Handles the sequential flow from `pending` through `reviewing`:
`start_processing!` → clone → `clone_complete!` → check spec → `spec_clear!` → implement → `impl_complete!` → commit → `commit_complete!` → push → `push_complete!` → create MR → `mr_created!` → review → `review_complete!`

### MrFixer

Handles `fixing_discussions`: clones the MR branch, fetches unresolved discussions, fixes each one via `danger-claude -p` + `-c`, resolves discussions, pushes. Fires `discussions_fixed!` → `checking_pipeline`.

### PipelineMonitor

Handles `checking_pipeline`: fetches MR head pipeline via GitLab API. If running → skip. If green → fires `pipeline_green!` (guards decide `over` vs `fixing_discussions`). If red → retrigger once, then evaluates via danger-claude. Code-related → fires `pipeline_failed_code!` → `fixing_pipeline` → `pipeline_fix_done!`. Non-code → `pipeline_failed_infra!` → `blocked`.

Pipeline fix strategy: full job logs are written to `tmp/ci_logs/<job_name>.log` files in the work directory (no truncation). Prompts reference these files by path so danger-claude reads the complete log. Each failed job is fixed in a separate danger-claude call + commit (same pattern as MrFixer's per-discussion approach).

### WorkerPool

N threads (configurable) consuming a shared `Queue`. Each worker gets its own GitLab client for thread safety. Graceful shutdown via SIGINT/SIGTERM.

## SQLite Schema

Single table `issues` with AASM status lifecycle:

```
pending → cloning → checking_spec → implementing → committing → pushing → creating_mr → reviewing
                                                                                          ↓
                                                                              checking_pipeline ←─────────┐
                                                                             /        |         \         │
                                                                   (green,           (red,     (red,      │
                                                                    no convos)        code)     infra)    │
                                                                       ↓               ↓         ↓       │
                                                                     over     fixing_pipeline  blocked    │
                                                                                    │                     │
                                                               (green,              │                     │
                                                                convos)             │                     │
                                                                  ↓                 │                     │
                                                          fixing_discussions────────┴─────────────────────┘

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
| Issue closed between poll and processing | `clone_complete!` → over (guard: issue_closed?) |
| Issues in error at startup | `recover_on_startup!` resets to pending |
| Pipeline red (first time) | Retrigger once, recheck next poll |
| Pipeline red (after retrigger) | Evaluate via Claude: code → fixing_pipeline, non-code → blocked |
| Pipeline canceled/skipped | `pipeline_canceled!` → blocked |
| Interrupted fixing_pipeline | Reset to checking_pipeline on startup |

## Key Design Decisions

- **AASM state machine**: Formalized transitions prevent invalid state changes. Guards handle conditional branching. `after_all_transitions :persist_status_change!` auto-saves.
- **No pass-through states**: `done` and `mr_fixed` eliminated. Direct transitions from `reviewing`/`fixing_*` to `checking_pipeline`.
- **Single-file CLI**: Same pattern as `mr-review` and `danger-claude` — `bundler/inline` for dependencies.
- **Dynamic model**: Issue Sequel::Model defined after DB connection via `Database.build_model!` using `Class.new(Sequel::Model(...))`.
- **Thread pool over processes**: Simpler resource management, shared Queue, per-worker GitLab clients for thread safety.
- **danger-claude as implementation engine**: Leverages the existing Docker-based Claude CLI wrapper for sandboxed code generation.
- **Non-fatal review**: `mr-review` failure doesn't block the MR creation pipeline.
- **Reactive shutdown**: Sleep loop checks shutdown flag every 1 second.

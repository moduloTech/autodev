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

### Config file example (`~/.autodev/config.yml`)

```yaml
gitlab_url: https://gitlab.example.com
gitlab_token: glpat-xxxxxxxxxxxxxxxxxxxx
trigger_label: autodev
poll_interval: 300
max_workers: 3
database_url: sqlite://~/.autodev/autodev.db

projects:
  - path: group/project-name
    target_branch: develop
    labels_to_remove:
      - "development::todo"
      - "todo"
    label_to_add: "Development::Awaiting CR"
    extra_prompt: "Use RSpec for tests"
```

### CLI flags

- `-c` / `--config PATH` — Config file path
- `-d` / `--database-url URL` — SQLite connection URL
- `-t` / `--token TOKEN` — GitLab API token
- `-n` / `--max-workers N` — Concurrent workers
- `-i` / `--interval SECONDS` — Poll interval
- `--once` — Single poll cycle then exit
- `-h` / `--help` — Show help

## Architecture

The script has three main components:

### Main loop

Polls GitLab projects for issues with the trigger label, checks the DB for already-processed issues, and enqueues new ones into the worker pool.

### IssueProcessor

Handles the full lifecycle for a single issue:

1. **Clone** — `git clone` into `/tmp/autodev_{project}_{iid}/`
2. **Branch** — `git checkout -b autodev/{iid}-{title-slug}`
3. **CLAUDE.md** — If absent, generate via `danger-claude -p` then commit
4. **Implement** — `danger-claude -p` with full issue context (title, description, comments, linked items)
5. **Commit** — `danger-claude -c`
6. **Push** — `git push -u origin`, retry with `--force-with-lease` on failure
7. **Labels** — Remove configured labels, add completion label via GitLab API
8. **MR** — Create via GitLab API with `Fixes #{iid}` in description
9. **Review** — `mr-review -H` (non-fatal)
10. **Cleanup** — Remove temp directory

### MrFixer

Handles `mr_fixing` issues: clones the MR branch, fetches unresolved discussions, fixes each one via `danger-claude -p` + `-c`, resolves discussions, pushes. After fixing → `mr_fixed`.

### PipelineMonitor

Handles `mr_pipeline_running` issues: fetches MR head pipeline via GitLab API. If running → skip. If green → checks for unresolved conversations (none → `over`, some → `mr_fixing`). If red → retrigger once, then on re-fail evaluates via `danger-claude` whether the failure is code-related (`mr_fixing`) or not (`blocked`).

### WorkerPool

N threads (configurable) consuming a shared `Queue`. Each worker gets its own GitLab client for thread safety. Graceful shutdown via SIGINT/SIGTERM: finish current work, don't take new issues.

## SQLite Schema

Single table `issues` with status lifecycle:

```
pending → cloning → implementing → committing → pushing → creating_mr → reviewing → done
                                                                                      ↓
done/mr_fixed → mr_pipeline_running → (green + no conversations) → over (terminal)
                       ↓ (green + conversations)
                    mr_fixing → mr_fixed → mr_pipeline_running (loop, capped by max_fix_rounds)
                       ↓ (code-related pipeline failure)
                    mr_pipeline_fixing → mr_fixed → mr_pipeline_running (loop, capped by max_fix_rounds)
                       ↓ (non-code failure)
                    blocked

error (any stage) → pending (on restart, with backoff)
needs_clarification → pending (when clarification comment posted)
```

Errored issues are automatically reset to `pending` on restart for retry.

## Error Handling

| Case | Behaviour |
|------|-----------|
| `danger-claude` not installed | Abort at startup |
| `mr-review` not installed | Warning at startup, review step skipped |
| Clone fails | status=error, next issue |
| No changes produced | status=error "No changes produced" |
| Push fails | Retry with --force-with-lease |
| MR already exists for branch | Reuse existing MR |
| Issue closed between poll and processing | Skip, mark done |
| Issues in error at restart | Auto-reset to pending for retry |
| Pipeline red (first time) | Retrigger once, recheck next poll |
| Pipeline red (after retrigger) | Evaluate via Claude: code → mr_fixing, non-code → blocked |
| Pipeline canceled/skipped | status=blocked, comment posted |

## Key Design Decisions

- **Single-file CLI**: Same pattern as `mr-review` and `danger-claude` — `bundler/inline` for dependencies.
- **Thread pool over processes**: Simpler resource management, shared Queue, per-worker GitLab clients for thread safety.
- **danger-claude as implementation engine**: Leverages the existing Docker-based Claude CLI wrapper for sandboxed code generation.
- **Non-fatal review**: `mr-review` failure doesn't block the MR creation pipeline.
- **Reactive shutdown**: Sleep loop checks shutdown flag every 1 second.

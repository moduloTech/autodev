# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A single-file Ruby CLI tool (`bin/autodev`) distributed via Homebrew (`modulotech/tap`) that automates the implementation of GitLab issues. It polls configured projects for issues assigned to the autodev user with a `label_todo`, clones the repo, implements changes via `danger-claude`, commits, pushes, creates a Merge Request, waits for a green pipeline, then runs `mr-review` for automated code review.

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

1. **Defaults** — `poll_interval: 300`, `max_workers: 3`, `pickup_delay: 600`, `stagnation_threshold: 5`
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
- `--status` — Show dashboard of tracked issues and exit
- `--all` — Include completed (`done`) issues in `--status`
- `--errors [IID]` — Show details for errored issues (all or specific)
- `--reset [IID]` — Reset errored issues to pending (all or specific)
- `-v` / `--version` — Show version and exit
- `-h` / `--help` — Show help

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

`setup`/`test`/`lint`: lists of commands (Docker CMD format, array of strings).
`run`: list of `{ command:, port: }` entries. `port` is optional — only entries with `port` get a Docker port mapping.

When any project has `app.run` entries with ports, Chrome DevTools is auto-enabled at startup (Chrome headless + MCP injection). No separate flag needed.

### Screenshot Workflow

When `app.run` is configured with ports, prompts instruct Claude to:
1. Launch background servers after implementation
2. Navigate impacted pages via Chrome DevTools MCP
3. Save PNG screenshots + `index.json` manifest in `/tmp/autodev_screenshots_<project>_<iid>/`

After danger-claude returns, `ScreenshotUploader` reads the manifest, uploads each PNG to GitLab (`client.upload_file`), and posts a formatted comment on the issue. Screenshots from MR discussion fixes are annotated with *(correction suite a review)*.

Screenshot instructions are injected in implementer and MR fixer prompts only (not pipeline fixer).

## Architecture

### State Machine (AASM)

The Issue model uses the `aasm` gem for a formalized state machine. Each state = one action. Events define valid transitions with guards.

The Issue Sequel::Model is built dynamically after DB connection via `Database.build_model!`.

**States (16):** `pending`, `cloning`, `checking_spec`, `implementing`, `committing`, `pushing`, `creating_mr`, `reviewing`, `checking_pipeline`, `fixing_discussions`, `fixing_pipeline`, `running_post_completion`, `answering_question`, `needs_clarification`, `done`, `error`

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
- **Red (infra, after retrigger)** → stay in `checking_pipeline` (manual intervention needed)
- **Canceled/skipped** → stay in `checking_pipeline` (manual intervention needed)

Pipeline fix strategy: full job logs are written to `tmp/ci_logs/<job_name>.log` files in the work directory (no truncation). Prompts reference these files by path so danger-claude reads the complete log. Each failed job is fixed in a separate danger-claude call + commit (same pattern as MrFixer's per-discussion approach).

### Poller

Polls for issues assigned to the autodev user with `labels_todo`. Also monitors:
- **Unassignment detection**: active issues no longer assigned → `done`
- **Post-completion**: `done` issues where autodev is unassigned + `post_completion` configured + MR not merged/closed → `running_post_completion` → `done`
- **Reentry**: `done` issues with `label_todo` detected → `reenter!` → `pending` (resets stagnation signatures and review count)
- **Pickup delay**: issues created less than `pickup_delay` seconds ago are skipped

### WorkerPool

N threads (configurable) consuming a shared `Queue`. Each worker gets its own GitLab client for thread safety. Graceful shutdown via SIGINT/SIGTERM.

## SQLite Schema

Single table `issues` with AASM status lifecycle:

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
| Issues in error at startup | `recover_on_startup!` resets to pending |
| Pipeline red (code by pre-triage) | Skip retrigger, go straight to fix phase |
| Pipeline red (infra/uncertain, first time) | Retrigger once, recheck next poll |
| Pipeline red (infra/uncertain, after retrigger) | Stay in checking_pipeline (manual intervention) |
| Pipeline canceled/skipped | Stay in checking_pipeline (manual intervention) |
| Stagnation detected (pipeline or discussions) | Transition to done with alert comment |
| Review limit reached (3 rounds) | Transition to done with alert comment |
| Unassigned during implementation | Transition to done at next poll cycle |
| Interrupted fixing_pipeline | Reset to checking_pipeline on startup |
| Interrupted reviewing | Reset to checking_pipeline on startup |
| Post-completion command fails | Non-fatal: error stored in `post_completion_error`, issue still transitions to `done`, visible via `--errors` |
| Interrupted running_post_completion | Reset to `done` on startup (non-fatal, not re-executed) |

## Key Design Decisions

- **AASM state machine**: Formalized transitions prevent invalid state changes. Guards handle conditional branching. `after_all_transitions :persist_status_change!` auto-saves.
- **Review after pipeline**: `mr-review` runs after the first green pipeline, not immediately after MR creation. This ensures the pipeline is stable before review comments are generated.
- **Stagnation detection**: Replaces `max_fix_rounds`. SHA256 signatures of failed job names (pipeline) or unresolved discussion IDs (discussions) detect when the same failures repeat consecutively. Configurable threshold (`stagnation_threshold`, default 5).
- **Polling by assignee**: Issues are discovered by querying GitLab for issues assigned to the autodev user with `labels_todo`, replacing the old `trigger_label`-based approach.
- **3 labels only**: `labels_todo`, `label_doing`, `label_mr`. Label stays `label_doing` during the entire implementation + pipeline + fix + review cycle, and switches to `label_mr` only when reaching `done`.
- **Post-completion at unassignment**: The `post_completion` hook triggers when autodev is unassigned from a `done` issue (not immediately after pipeline green).
- **No blocked state**: Infrastructure failures and canceled pipelines keep the issue in `checking_pipeline` indefinitely until manual intervention or natural resolution.
- **Single-file CLI**: Same pattern as `mr-review` and `danger-claude` — `bundler/inline` for dependencies.
- **Dynamic model**: Issue Sequel::Model defined after DB connection via `Database.build_model!` using `Class.new(Sequel::Model(...))`.
- **Thread pool over processes**: Simpler resource management, shared Queue, per-worker GitLab clients for thread safety.
- **danger-claude as implementation engine**: Leverages the existing Docker-based Claude CLI wrapper for sandboxed code generation.
- **Reactive shutdown**: Sleep loop checks shutdown flag every 1 second.

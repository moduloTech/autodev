# Changelog

## [Unreleased]

### Added

- `RepoOperations#log_push_diagnostics` logs `git log -1 --stat HEAD` and `git count-objects -vH` before every `push_with_lease_fallback` invocation, and `log_large_blobs` lists the top 10 blobs by on-disk pack size when a push is rejected with `pack exceeds maximum allowed size`. Motivated by Powerpanne issue #15930 (2026-06-03): a reentry-triggered re-implementation produced a commit whose pack exceeded GitLab's 50 MiB `receive.maxInputSize` limit (`remote: fatal: pack exceeds maximum allowed size (50.00 MiB)` / HTTP 500), `IssueProcessor#process_issue` `rm_rf`'d the work_dir in `ensure` before the cause could be inspected, and the log captured nothing beyond the truncated stderr — no way to tell whether `vendor/bundle`, `public/packs`, or a stray binary was the culprit. The diagnostics run on every push (cheap: two git commands, ~50 ms total), so we always have HEAD's file-stat and the pack-byte counts in the log; the large-blob enumeration only runs on the specific rejection pattern, via `Open3.pipeline_r(rev-list --objects --all | cat-file --batch-check)` filtering to `blob` entries with on-disk size. Both helpers are wrapped in `rescue StandardError` so a git failure mid-diagnostic can never break a push that was otherwise going to succeed. Used by all three call sites that push: `IssueProcessor::GitOperations#push`, `MrFixer::FixCycle#push_fixes`, `PipelineMonitor::PipelineFixer#push_branch`, and `RepoRebaser#rebase_branch_on_target`.

## [0.15.1] - 2026-06-02

### Fixed

- `RateLimitDetector::PATTERN` did not match claude-code's `"You've hit your session limit"` variant — only `"your limit"`, `"rate limit"`, and `"usage limit"` were caught. When the API returned the session-limit phrasing, `RateLimitDetector.check!` silently returned, danger-claude exited non-zero, and the caller raised `ImplementationError` instead of `RateLimitError` — bypassing the rate-limit pause logic in `IssueProcessor::ErrorHandler`, `MrFixer::ErrorHandler`, and `PipelineMonitor::FailureHandler`. Observed in production on Powerpanne issues #15643 / #15737 / #15855 / #15125 / #16044 (2026-06-02): all marked `error` with `"session limit · resets HH:MMam (UTC)"` in stdout when they should have paused and retried. Pattern is now `/you've hit your (?:session |usage )?limit|rate limit|usage limit/i` and covers all three claude phrasings. While auditing, also fixed `RESET_PATTERN` to accept hour-minute formats — the original `(\d{1,2})(am|pm)` regex silently dropped `:30` in `"resets 11:30am (UTC)"`, setting the pause window to the wrong wall-clock time (always on the hour). Now matches both `"6pm"` and `"11:30am"` with minutes parsed and passed to the pause schedule. Six tests in `test/rate_limit_detector_test.rb` cover all three limit phrasings, an unrelated-failure negative case, and both reset-time formats.

- `RepoRebaser#resolve_conflicts_then_continue` did not catch exceptions from `danger_claude_prompt`. When danger-claude itself failed during conflict resolution (rate limit, session limit, or any other non-zero exit), the raise propagated up uncaught, leaving the work tree in a half-rebased state and crashing whatever pipeline was calling the rebase (PipelineFixer, MrFixer, or IssueProcessor). Observed on Powerpanne issue #15643 (2026-06-02) with v0.15.0: pipeline fix attempted, rebase produced a conflict, claude was invoked to resolve, claude hit a session limit, `ImplementationError` propagated through the full call stack (the exact stack frame `repo_rebaser.rb:55 → repo_rebaser.rb:27 → pipeline_monitor/failure_handler.rb:98` confirmed the path). Now wrapped: `RateLimitError` propagates after `git rebase --abort` (the worker still pauses, but the tree is clean for resume); any other exception is logged, the rebase is aborted, and the helper returns `:failed` — the caller falls back to running on the unmodified branch instead of crashing. Two regression tests in `test/repo_rebaser_test.rb` cover the `ImplementationError → :failed + abort` and `RateLimitError → reraise + abort` paths, both verifying via `.git/rebase-{apply,merge}` that the rebase is no longer in progress after the helper returns.

## [0.15.0] - 2026-06-02

### Added

- Auto-rebase the autodev branch onto its target before every write action. Without this, danger-claude operates against a stale tree: when `target_branch` moves forward between Autodev's first push and a later iteration (reentry, MR-fix round, pipeline-fix round), the implementation/fix runs on the old base, MrFixer wrestles with thread positions on lines that have shifted, PipelineFixer sees test failures that wouldn't exist on a rebased branch, and the MR may pile up conflicts before merge. New `RepoRebaser` mixin (included via `DangerClaudeRunner` so all three classes inherit it) exposes `rebase_branch_on_target` — fetches the target with an explicit refspec (so `refs/remotes/origin/<target>` actually exists; `git fetch origin <branch>` alone only writes `FETCH_HEAD` on single-branch clones), skips the rebase if `git log HEAD..origin/<target>` is empty, tries a clean `git rebase`, and on conflict invokes danger-claude with a focused prompt to resolve files (claude stages, the helper runs `git rebase --continue` with `GIT_EDITOR=true` to auto-accept the original commit message). If claude can't resolve, the helper `git rebase --abort`s and returns `:failed` — the branch is left in its pre-rebase state so the downstream action runs on stale-but-clean ground instead of being blocked. Shallow-aware: probes `git rev-parse --is-shallow-repository` and uses `--deepen=500` on shallow clones (500 commits is roughly several weeks of staging activity for Powerpanne, the largest tracked repo), normal fetch on full clones. Three call sites: `IssueProcessor::GitOperations#resolve_branch` (when reusing an existing autodev branch), `MrFixer::FixCycle#run_fix_cycle`, and `PipelineMonitor::FailureHandler#prepare_work_dir`. Five tests in `test/repo_rebaser_test.rb` exercise the helper against a real on-disk bare repo with diverging branches: no-op when target hasn't moved, clean rebase when target advanced without conflict, conflict resolved by claude → rebased and pushed, conflict left untouched by claude → abort + `:failed`, and verifies the abort path actually rewinds HEAD to its pre-rebase SHA.

- `DiscussionSnapshot` instrumentation module that captures a ground-truth snapshot of every MR discussion at three critical moments: `:post_mr_review` (right after mr-review returns successfully), `:pre_fix_dispatch` (in `PipelineMonitor#green_post_review`, just before the AASM routes to `done` vs `fixing_discussions`), and `:pre_mr_fix` (in `MrFixer#process_discussions`). Motivated by Powerpanne issue #11859 (2026-05-28): `green_post_review` saw `count: 0` and transitioned to `done` immediately after the only successful mr-review run of the day, yet 12 unresolved threads were visible on the MR when the user looked. Without per-discussion state captured at both sides of the suspected race (mr-review draft note publication vs autodev's next fetch), the root cause cannot be pinned. Each snapshot records, per discussion: short id, author username, first-note created_at, total/resolvable/resolved note counts, an `unresolved` boolean computed identically to `fetch_unresolved_discussions`'s filter, and a position string (`path:line`, or `path:outdated` when `new_line` is null, or `general` for non-diff comments). Snapshots are logged at DEBUG and persisted as `activity_events` rows with `kind='discussions_snapshot'` so they can be queried via SQL on the prod DB. The module is intentionally defensive — API errors, missing methods, persistence failures are all swallowed — so the instrumentation can never break the workflow it's instrumenting. Web UI displays snapshots in the activity timeline as raw JSON (via `format_event`'s default branch), no template change required. Six tests in `test/discussion_snapshot_test.rb` cover payload shape, position-string variants (general/diff-line/outdated), persistence, and graceful degradation on API failure.

### Fixed

- mr-review failures used to silently loop forever. `Reviewer#launch_review` incremented `review_count` only on success (line 15 of `pipeline_monitor/reviewer.rb`) but fired `issue.review_done!` unconditionally (line 16), so a failing mr-review run sent the issue back to `checking_pipeline` with `review_count` still at 0; the next poll cycle re-entered `green_first_review` and tried mr-review again. With nothing to bound the failure side, a persistently broken mr-review (token expired, binary crash, transient GitLab errors) ran indefinitely. Observed on Powerpanne issue #11859 (2026-05-28): 37 `checking_pipeline → reviewing` transitions in ~100 minutes before a single 15-min run finally succeeded. Now: a new `review_failure_count` column tracks consecutive failures; on success the counter resets, on failure it increments. At `REVIEW_FAILURE_THRESHOLD = 5` consecutive failures, a new AASM event `review_giveup!` fires (`reviewing → done`) with a localized alert (`review_failures_exhausted` notification + `:review_failures_exhausted` activity log) and the issue is reassigned to the author — same UX contract as `max_review_rounds_reached`. The counter is reset in `PollRouter::ResumeHandler` on both reentry paths so a re-engaged ticket starts with a clean slate. Tests: `test/pipeline_monitor_review_failure_test.rb` covers all five behavioural assertions (counter increments, sub-threshold returns to `checking_pipeline`, threshold transitions to `done`, success resets counter, success increments `review_count`); `test_review_giveup_from_reviewing_goes_to_done` in `database_advanced_test.rb` covers the new AASM event.

- Reentry from `done` (user re-adds a `labels_todo` label on a finished issue) always routed back to `pending` and triggered a full re-implementation cycle, even when the existing MR was still open with unresolved review threads. Observed in production on Powerpanne issue #11859 (2026-05-28, MR !10681): the user re-added the `To do` label expecting Autodev to address the 12 outstanding bot/reviewer threads; instead `PollRouter::ResumeHandler#handle_reenter` fired `reenter!` → `pending` → clone → checking_spec → implementing → MR update, and MrFixer never ran (`fix_round` stayed at 0). The reset of `review_count: 0` also forced the pipeline-green path through `green_first_review` (mr-review) instead of `green_post_review` (which is what routes to `fixing_discussions`). `PollRouter::ResumeHandler` now inspects the MR state on reentry: if `mr_iid` is set and the MR is `opened`, fire a new AASM event `reenter_to_check_pipeline` (`done → checking_pipeline`), pin `review_count: 1`, and apply `label_doing` immediately. The next `poll_pipelines` tick in the same cycle picks up the issue and `green_post_review` either dispatches to `fixing_discussions` (unresolved threads exist) or transitions cleanly to `done` (everything already addressed). The original re-implementation path is preserved as the fallback when no MR exists or the MR is closed/merged — that's still the right behavior when the spec changed or the previous work was discarded. `review_count` is pinned to `1` (not preserved) on purpose: preserving a value `>= MAX_REVIEW_ROUNDS` would short-circuit straight back to `done` via the `max_review_rounds_reached?` guard. Tests: new `test/poll_router_reenter_test.rb` covers the three branches (MR open → checking_pipeline, MR closed → pending, no MR → pending), plus a regression on the review_count pin; `test_reenter_to_check_pipeline_from_done` in `database_advanced_test.rb` covers the new AASM event in isolation.

## [0.14.3] - 2026-06-02

### Fixed

- Bump bundler/inline pin of the `gitlab` gem from `~> 5.0` to `~> 5.1`. The previous pagination fix (commit `1191332`) passes `per_page: 100` to `client.merge_request_discussions(...)`, but the 5.0.0 signature is `def merge_request_discussions(project, merge_request_id)` — no options arg, so Ruby 3.x raised `ArgumentError: wrong number of arguments (given 3, expected 2)` on every pipeline check for users still on 5.0.0. The 5.1.0 signature added `options = {}` (where `auto_paginate` and `per_page` work as expected). Observed in production on Powerpanne issue #15930 immediately after deploying v0.14.2. `auto_paginate` itself exists in 5.0.0, only the `merge_request_discussions` call accepts options starting in 5.1.0.
- Activity-log note overflow on issues stuck in `checking_pipeline`. Observed in production: GitLab returning `400 Bad request - Note is too long (maximum is 1000000 characters)` on every poll for notes 821372 and 820384 (Powerpanne issues #15676 and #15839). Root cause: per the "no blocked state" design, an issue with an infra-side pipeline failure stays in `checking_pipeline` indefinitely until manual intervention. On each poll cycle, `PipelineMonitor::FailureHandler#triage_and_fix` emitted two activity-log entries (`pipeline_red` + `pipeline_infra`) that appended unconditionally — at the default `poll_interval: 300`, this added ~576 lines/day (~40 KB/day) and crossed GitLab's 1M-char cap after ~25 days. Once the note crossed the cap, every subsequent `edit_issue_note` returned 400 and the rescue swallowed it, so autodev kept logging the same failure on every tick. Two complementary fixes:
  - **Source-side dedup**: `pipeline_red`, `pipeline_infra`, and `pipeline_evaluating` now pass a `replace_pattern` to `log_activity` so each new emission replaces the previous one in place instead of appending. `ActivityLogger.replace_or_append` also now uses `rindex` to find a match anywhere in the body, not only on the last line — without that, three different recurring events interleaved on the same poll cycle would each break the next one's dedup because the "last line" is whatever the previous event in the same cycle just appended (the existing `pipeline_checking` dedup was already affected by this in the failing-pipeline path).
  - **Sink-side size guard**: `ActivityLogger.upsert` now checks `body.length > MAX_NOTE_BYTES` (900_000, conservative under GitLab's 1M cap) and truncates if needed. Strategy: keep the 2-line header, inject a localised marker (`activity_truncation_marker`, FR/EN), then keep the most recent tail lines that fit under the budget — older entries fall off. Idempotent: the marker is recognised and skipped on subsequent truncations so it doesn't stack. This also auto-repairs the existing oversized notes on the next emission: GET returns the >1M body, the guard truncates it, and the PUT succeeds.

  Three regression tests in `test/activity_logger_overflow_test.rb` cover both layers and the FR/EN marker selection. Verified the rindex regression specifically by temporarily reverting to the `lines.last` semantics — the corresponding test failed immediately with "replaces match not at tail".

## [0.14.2] - 2026-06-01

### Added

- Smoke test `test/module_load_test.rb` that requires every `lib/autodev/*.rb` file and asserts none raise at load. Skips `LoadError` (gem missing in test gemset is not a code regression) but flags `NameError` / `ScriptError` / other `StandardError` — exactly the class of bug that caused the 0.14.0 → 0.14.1 hotfix (`usage_checker.rb` aliasing a moved constant). Verified by temporarily reverting the hotfix: the new test fails with the same error the user hit at CLI boot, then passes again once the alias is corrected.

### Fixed

- `fetch_unresolved_discussions` in `pipeline_monitor/api_helpers.rb` and `mr_fixer.rb` was calling `@client.merge_request_discussions(...)` without any pagination param. The `gitlab` gem defaults to `per_page: 20` and returns a `Gitlab::PaginatedResponse`; any MR whose timeline (commit notes, system "added N commits" notes, "mentioned in" notes, inline review threads, "changed this line in version X" notes…) accumulated more than 20 entries was silently truncated to the first page. Observed in production on Powerpanne MR !10699 (24 total discussions): the 3 unresolved review threads at positions #21-#23 stayed open forever — autodev resolved the 6 round-2 threads visible on page 1, then `fetch_unresolved_discussions` returned `[]` on the next poll cycle and the AASM transitioned to `done` via the `no_unresolved_discussions?` guard, abandoning the trailing threads. Both call sites now pass `per_page: 100` and chain `.auto_paginate` so every page is walked. Two regression tests (`test/pipeline_monitor_fetch_unresolved_discussions_test.rb`, `test/mr_fixer_fetch_unresolved_discussions_test.rb`) wrap the client in a fake `PaginatedResponse` whose first-page array behaves identically to an Array (via `method_missing`) but only reveals trailing pages through `auto_paginate` — verified by temporarily reverting the production fix: the test fails with "fetch_unresolved_discussions must call auto_paginate", then passes once `.auto_paginate` is restored.
- Audit follow-up to the discussion pagination fix: every other `client.*` list endpoint in `lib/autodev/gitlab_helpers.rb` was either using the default `per_page: 20` or capped at `per_page: 100` without walking pages. Four call sites now chain `.auto_paginate`:
  - `fetch_mr_discussions_context` (`merge_request_discussions`) — same bug as the main fix, in the path that builds the context file fed to danger-claude for MR fix iterations and question-investigation prompts. With the previous code, Claude saw a truncated review history on MRs ≥ 20 entries and made decisions on a partial view.
  - `clarification_answered?` (`issue_notes`) — used to detect whether the user has replied to an autodev clarification request. On a long-running issue with > 100 timeline entries (label changes, mentions, comments), a reply hiding past note #100 would never be detected and the issue would stay in `needs_clarification` forever.
  - `IssueFormatter.append_comments` (`issue_notes`) — truncated the user-comment section of the danger-claude context past note #100.
  - `fetch_assignee_issues` (`issues`) — silently capped autodev's pickup queue at 100 open issues per project. Unlikely to bite in steady state but a real cliff on backlog imports.

  No new bug observed for these three secondary call sites yet, but the failure mode (silent truncation, no error, no log line) is the same as the MR !10699 incident and would only surface as "autodev stopped doing X on this ticket". One regression test (`test/gitlab_helpers_pagination_test.rb`) covers the two highest-impact paths (`fetch_mr_discussions_context` and `clarification_answered?`) with the same fake-PaginatedResponse harness used for the main fix.

## [0.14.1] - 2026-05-13

### Fixed

- `bin/autodev` was crashing at startup with `uninitialized constant DangerClaudeRunner::RATE_LIMIT_PATTERN`. The 0.14.0 refactor moved the regex out of `DangerClaudeRunner` into a new `RateLimitDetector` module, but missed updating `lib/autodev/usage_checker.rb:10` which still aliased the old constant. The class-level alias is evaluated at file load, so any invocation of the CLI (which `require`s the full `autodev` module) failed before reaching the entrypoint. Existing tests didn't catch this because `autodev_test_helper.rb` loads only the submodules it needs, not the full `autodev` module — so `usage_checker.rb` was never required in CI. Switched the alias to `RateLimitDetector::PATTERN`.

## [0.14.0] - 2026-05-13

### Added

- Session reuse across same-model phases (MR fix loop, pipeline fix loop, implement→commit), threaded via a new `resume:` keyword on `DangerClaudeRunner#danger_claude_prompt` and `#danger_claude_commit` that maps to danger-claude's `-r SESSION_ID`. The runner always emits `--output-format json` so it can parse `session_id` out of the claude-code envelope and stash it as `@last_session_id`. MR fix and pipeline fix now ship a full-context prompt only on the first iteration and a short "next thread/job" follow-up on subsequent ones (claude already has issue + MR/CI context in the resumed session). The implement→commit chain auto-resumes the implementer's session when the single-agent path was taken (resets to `nil` for split/parallel where multiple concurrent sessions would race). Requires danger-claude ≥0.5.7 (commit mode now forwards `--resume` and `--output-format`). Side benefit: prompt caching on resumed turns cuts the token cost of the implicit conversation history on top of the shorter user prompts. New mixin modules `RateLimitDetector` and `RepoOperations` extracted from `DangerClaudeRunner` to keep the runner under the rubocop line limit after the new code landed; new `MrFixer::FixPrompts` sibling to `PipelineMonitor::FixPrompts` does the same for `FixCycle`. New `**Modèle :**` and follow-up template documentation in `autodev-prompts.md`. When the JSON envelope parse fails (older danger-claude, corrupted output), the runner emits a warn-level activity event (`activity_dc_parse_failed`) so the operator sees session reuse degraded silently in the web UI; `ActivityLogger.persist_event!` now accepts a `level:` keyword and a new `ActivityLogger.warn_event(issue, key, **vars)` writes to the activity_events DB only (no GitLab note spam for tech signals). Each host class (`IssueProcessor`, `MrFixer`, `PipelineMonitor`) stashes `@dc_issue` at its entry point so the runner can attach the warning to the right issue.
- Per-prompt model selection via a new `model:` keyword on `DangerClaudeRunner#danger_claude_prompt`, threaded through `dc_global_args(model_default:)`. The three JSON-classifier prompts (spec check, complexity evaluation, pipeline-failure evaluation) now default to `haiku` since they produce a short structured response and don't need a heavyweight model. Resolution stays `project_config['model']` > global `config['model']` > per-call default, so any operator already overriding the model globally keeps full control. The implementation prompts (single, parallel, pipeline fix, CLAUDE.md gen, question investigation) keep inheriting from config; the split-code / split-tests / MR-fix prompts remain pinned to `sonnet` via their agent frontmatter. Catalog in `autodev-prompts.md` updated with a per-prompt model table and a `**Modèle :**` line on every section.

### Fixed

- `DangerClaudeRunner#danger_claude_prompt` now forwards its `agent:` keyword to danger-claude as `-a NAME` so claude-code actually uses the requested subagent. Previously the parameter was accepted and logged but never wired through, so callers that asked for `mr-fixer`, `implementer`, or `test-writer` were silently falling back to claude-code's auto-agent selection from the description-based discovery of `.claude/agents/*.md`. With the fix the agent is now deterministically selected, matching the original intent of `detect_agent` / `inject_default_agent`. The agent file is still written to disk by the injector for claude-code to read; the change is purely about telling claude-code which one to run.

### Changed

- Lower default retry & timeout limits to reduce quota burn on Claude rate limits. `max_retries` 3 → 1, `retry_backoff` 30s → 10s, `dc_timeout` 1800s (30 min) → 600s (10 min). Rationale: on a Max/Team seat shared by autodev's bot, every retry replays the full pipeline and re-consumes the weekly quota; the old defaults were sized for transient API flakes (which are now rare) but turned each failing ticket into a 3× cost multiplier. The 30-min timeout also let runaway sessions silently burn through token budget. Defaults applied in `Config::DEFAULTS`, `Config::TEMPLATE` comments, and the `process_runner.rb` fallback. Per-project overrides via `dc_timeout` / `max_retries` / `retry_backoff` in `~/.autodev/config.yml` still work for projects that genuinely need more headroom.

## [0.13.0] - 2026-05-12

### Fixed

- `MonitorHandler#poll_retries` now also picks up issues stuck in `pending` after a previous retry. Previously, when a mid-implementation failure flipped `error → pending` via `retry_processing!`, `restore_labels` reapplied `Development::Doing` on the GitLab side — and from that point onwards `Poller::IssueHandler.fetch_assignee_issues` (filtered by `labels_todo`) no longer returned the issue. The DB row was `pending` but nothing re-enqueued it, so the ticket sat idle for days/weeks. `fetch_retryable` now also matches `status = 'pending'` rows that have a `next_retry_at` in the past and `retry_count > 0`; for those it skips the AASM transition (already pending) and enqueues `IssueProcessor#process` directly. `next_retry_at` is cleared on re-enqueue so the same poll cycle doesn't fire twice. New `test/monitor_handler_fetch_retryable_test.rb` covers both branches plus the edges (fresh pending, future backoff, max_retries cap, project scoping).

### Added

- New "En attente" / "Pending" KPI card on the dashboard and matching tab on `/issues`. Pending issues (queued, not yet picked up by a worker) used to be invisible on the web — they don't fall in `Dashboard::ACTIVE_STATES` (in-flight only) and `/errors` / `/issues?tab=active` both skipped them. The KPI card surfaces the count, the tab makes them browsable. Reuses the existing `working` tone with a `clock` icon to distinguish from "En traitement" visually.

### Changed

- Rename the in-flight bucket from "En cours" / "Demandes en cours" to "En traitement" (FR) — matches the new distinction with "En attente" (pending, not yet started). Touches `web_kpi_in_progress`, `web_dashboard_active_section`, `web_tab_active`. EN label stays "In progress". The "X actives" sub-count next to the active section title now reads "(X)" — clearer once the title itself says "En traitement".

## [0.12.2] - 2026-05-12

### Changed

- Issue detail page (`/issues/:id`) now uses the same shell as the rest of the redesigned UI: sidebar with active "Demandes" entry, topbar with breadcrumb (`Demandes › <project> › #<iid>`) + title + GitLab/MR action buttons, status band (large status pill + branch + relative time), and a 1.5fr/1fr grid of cards (activity table, screenshots, raw JSON on the left; metadata KV + actions on the right). Previously this route was still on the old top-nav chrome because it was bundled with the chat panel work that stayed out of scope.
- Actions card on the issue detail page is now fully localized: the danger reset button reads "Réinitialiser" in FR (was an untranslated "Reset"), and the force-transition `<select>` now displays human-readable labels per AASM event (e.g. "Lancer le post-completion", "Marquer en erreur") instead of the raw symbol. Adds 23 `web_event_*` keys covering every event defined in `IssueBehavior` (FR + EN), a `Web::I18nHelpers#event_label` helper, and updates `layout.rb`'s `data-confirm-template` JS to interpolate the option's display text so the confirmation dialog matches what the user picked.

### Fixed

- On `/errors`, the "Voir la question" button on `needs_clarification` cards pointed to `/issues/<id>` — same destination as "Voir le détail" next to it. It now links to the GitLab issue URL (built via `gitlab_issue_url`), since the question is posted as a comment there and that's where the user actually replies. Falls back to the local detail page when `gitlab_url` isn't configured.
- Tooltips on `.coming-soon` elements never showed. The wrapper had `pointer-events: none`, which suppressed the hover events the browser needs to trigger the native `title="…"` tooltip. Move `pointer-events: none` to the children (`a`, `button`) only — clicks on the disabled control still do nothing, but the wrapper now receives hover so "Bientôt disponible" appears. Side effect: `cursor: not-allowed` now actually applies too (it was being swallowed by the same `pointer-events: none`).

### Removed

- The "Tout marquer comme lu" / "Mark all as read" button on `/errors`. It was a coming-soon stub with `pointer-events: none`, which only looked broken: users saw a button and clicked it expecting an action. Drop the button (and the `web_errors_mark_all_read` key in FR + EN) until the feature is actually implemented.

## [0.12.1] - 2026-05-11

### Added

- New `web.bind` config option (default `'127.0.0.1'`). Set to `'0.0.0.0'` or a specific interface IP to expose the embedded UI beyond loopback — e.g. to make it reachable from a NetBird mesh peer. `Web::Lifecycle.start` passes the value to `Puma::Server#add_tcp_listener`, and `ConfigValidator.validate_web_bind!` rejects empty strings / non-strings. Backward compatible: with no config change, the bind stays `127.0.0.1` and behavior is unchanged. **No built-in auth** — when binding off-loopback, put a reverse proxy or mesh VPN in front for TLS + access control.

## [0.12.0] - 2026-05-11

### Added

- New `activity_events` table (id, issue_id, created_at, kind, level, payload_json) with indexes on `(issue_id, created_at)` and `(kind, created_at)`. Foundation for the upcoming embedded web UI: structured per-issue activity log persisted alongside the existing GitLab note posted by `ActivityLogger`. `ActivityEvent` Sequel model exposes JSON payload helpers; built dynamically in `Database.build_model!` like `Issue`.
- `ActivityLogger.post` now also persists each entry to `activity_events` (kind: `danger_claude`, payload includes the i18n key, interpolation vars, and the rendered message). DB write happens before the GitLab API call and is wrapped in its own rescue so a DB failure never breaks the existing GitLab activity-log behavior.
- Every AASM transition on `Issue` now writes an `activity_events` row (kind: `transition`, payload: `{from, to, event}`). Wired via a new `emit_activity_event!` callback registered alongside `persist_status_change!` in the global `after_all_transitions`. Best-effort: any DB failure is swallowed to keep the state machine intact.
- New `Web::Server` Sinatra app (`lib/autodev/web/`) with full views and POST actions:
  - `/` dashboard: counters per AASM status, active issues grouped by status, breakdown per project.
  - `/issues/:id` detail: status badge, GitLab/MR links, metadata, activity timeline (200 most recent rows from `activity_events`), screenshots, raw JSON dump, plus inline action forms.
  - `/issues/:id.json` raw JSON of the row.
  - `/errors` lists `error` + `needs_clarification` + any issue with `post_completion_error`, each row with a Reset button.
  - `/projects/:slug` shows the project's `app:` config block plus its 100 most recent issues (slug encoding: `group/project` ↔ `group__project`).
  - `POST /issues/:id/reset` mirrors `--reset` for one issue.
  - `POST /issues/:id/transition` accepts only events from `issue.aasm.events(permitted: true)`; rejects unknown or non-permitted events with 422.
  - View helpers extracted to `Web::Helpers` module (status badge classes, GitLab URL builders, payload formatting, etc.).
  - Adds runtime deps `sinatra ~> 4.0`, `puma ~> 6.0`, `rack ~> 3.0`, and test-only `rack-test ~> 2.1`. Sinatra 4's host authorization is disabled because the server only ever binds to `127.0.0.1`.
- New `Web::EventBus` module: thread-safe in-process pub/sub used to fan ActivityEvent rows out to live SSE subscribers. Subscribers each get their own `Queue`; `publish` snapshots the subscriber list under a mutex so iteration doesn't block other publishers. Backpressure: queues over 100 events drop the oldest. `shutdown!` pushes a sentinel to every subscriber so `/stream` loops exit cleanly. `ActivityEvent.after_create` publishes the row to the bus (best-effort, swallowed if the bus isn't loaded).
- New `GET /stream` SSE endpoint on `Web::Server` (requires Puma's evented streaming, which is why we chose Puma in the previous step). One open connection per browser tab; each event is encoded as `event: <kind>\ndata: <json>\n\n`. The `data` payload is `{id, issue_id, kind, level, created_at, text}` — `text` is the human-readable rendering used by the activity timeline.
- `Web::Server` lifecycle: `Server.start(config)` boots a background Puma instance bound to `127.0.0.1`, threads `0..8`, returning the chosen port (or `nil` if disabled / `--once` / already running). `Server.stop` pushes the EventBus shutdown sentinel so `/stream` loops exit, then `Puma::Server#stop(true)` and `thread.join(5s)`. Lifecycle code lives in `Web::Lifecycle` (mixed in via `extend`) so the Sinatra class stays under the RuboCop length cap.
- `Poller#run` now starts the web server before entering the poll loop and stops it on shutdown — same SIGINT/SIGTERM handler, no extra trap.
- Config: new `web` block in `DEFAULTS` (`enabled: true`, `port: 4567`). `ConfigValidator.validate_web!` rejects non-hash blocks, non-boolean `enabled`, ports outside `[1024, 65535]`, and non-integer ports. The block is optional — its absence behaves like `enabled: false`.
- Live updates: SSE messages now ship Turbo Stream HTML instead of opaque JSON. Each `activity_events` row produces a `prepend` to the `events_<issue_id>` timeline. Transitions additionally emit a `replace` on `status_<issue_id>` so the badge on the issue detail page flips in real time. Targets that don't exist on the current page are silently ignored by Turbo — the same SSE feed can serve every browser tab.
- Vendored `@hotwired/turbo` (~217 KB UMD build) at `lib/autodev/web/public/turbo.js`, served via `GET /assets/turbo.js`. The layout pulls Turbo with `defer` and a tiny inline script subscribes to `/stream` with `EventSource` and forwards every message to `Turbo.renderStreamMessage`. No CDN, no extra build step.
- Issue detail page now wraps the activity table body in `id="events_<id>"` and the status badge in `id="status_<id>"` so Turbo Stream targets resolve.
- End-to-end integration test (`test/web_integration_test.rb`) boots the real Puma server on a free port, drives an issue through transitions, and asserts dashboard/timeline/reset all work over real HTTP. Plus per-step suites: `activity_event_test.rb`, `activity_logger_test.rb`, `issue_behavior_emit_event_test.rb`, `config_validate_web_test.rb`, `web_server_test.rb`, `web_actions_test.rb`, `web_event_bus_test.rb`, `web_sse_test.rb`, `web_lifecycle_test.rb`. Total: +43 new tests.
- `CLAUDE.md` gains a Web UI section documenting routes, lifecycle, EventBus, and the persistence wiring. `bin/autodev` help text and the YAML config template are updated with the new `web:` block. The CLI flags `--status`, `--errors`, `--reset` are kept as-is for headless / SSH / CI use.
- Web UI: dashboard counters are now clickable links to a generic `GET /list/:status` route (limit 500, ordered by id desc). Mirrors `--status --all` for any single AASM state — particularly useful for browsing `done` history, which had no UI entry point before.
- Web UI: the dashboard's "Par projet" section now lists every project with any tracked issue (active or done), with per-status counts (Total / Actives / Terminées / Erreur). Previously only projects with at least one *active* issue showed up — useless once everything was finished.
- Web UI: new `GET /issues` page (linked from the nav next to Dashboard / Erreurs) listing every tracked issue regardless of status, with: case-insensitive keyword search on title (SQL `%`/`_` escaped), `from`/`to` date filter on `created_at` (end-of-day inclusive), and pagination with user-selectable page size (20/50/100, default 50). Filter logic extracted to `Web::IssuesFilter` so it's testable without Sinatra. Pagination clamps an out-of-range `page` to the last available page.
- Web UI is now localized. Every hardcoded string in the ERB views was extracted to `Locales::WEB_TEMPLATES` (FR + EN) and looked up via a new `t_web(key, **vars)` helper (`Web::I18nHelpers`). The active locale comes from `web.locale` in config (default `'fr'`, validated to `'fr'` or `'en'`). Adding more languages is a one-file change in `lib/autodev/locales/web.rb`. Side note: `Web::Server` switched from Sinatra's `set :app_config, ...` to a direct class-level `attr_accessor` (in `Web::Lifecycle`) — Sinatra's `set` had a state-leak issue across tests when the value was a hash.
- Web UI: per-browser language switcher in the nav (top-right). Clicking `FR`/`EN` hits `GET /locale/:lang`, which sets a 1-year cookie and redirects to the previous page. Resolution order is now **cookie > config (`web.locale`) > default (`fr`)**, so a single user can flip language without touching the YAML. Invalid values in the cookie or URL are ignored. The `back` redirect param is sanitized to `/` if it doesn't start with `/` to prevent open-redirects.
- Web UI: status labels (`Terminée` / `Done`, `En cours` / `In progress`, etc.) now respect the active locale. Until now `Web::Helpers#status_label` delegated to `Dashboard.status_label`, which is hardcoded French (correctly so for the CLI `--status`). The web layer now has its own `web_status_*` keys in `Locales::WEB_TEMPLATES` and resolves them through `t_web`, while the CLI continues to read the French-only constants. Visible regression on the issue detail page when the user had picked `EN` in the switcher.
- Web UI: views migrated from ERB to **Phlex 2.4** (`gem 'phlex', '~> 2.4'`). All 7 templates (`layout`, `dashboard`, `issue_show`, `errors`, `project_show`, `list`, `issues`) are now Ruby classes under `Web::Views::*` inheriting from a shared `Web::Views::Base` (which includes `Web::Helpers` and stores the resolved `@locale`). Routes render via `Views::X.new(...).call` instead of `erb :x`. Two adjustments forced by Phlex 2's stricter API: `unsafe_raw` was replaced with `raw(safe(content))`, and inline `onsubmit="return confirm(...)"` was replaced with `data-confirm="..."` / `data-confirm-template="...$event..."` plus a single delegated `submit` listener in the layout (Phlex 2 rejects unsafe attribute names like `onsubmit`).
- Web UI: integrated the design-system tokens. `lib/autodev/web/public/css/tokens.css` (light + dark, ~200 CSS vars covering colors, accent violet, semantic statuses, radii, shadows, fonts) is the verbatim copy of the design handoff. `app.css` carries the app-shell rules (max-width, table/button styling, the legacy `.badge-*` bridge that helpers.rb still emits — to be replaced by StatusPill in the next task). `fonts.css` declares `@font-face` for Inter (400/500/600/700) + JetBrains Mono (400/500), pointing to vendored woff2 files under `public/vendor/fonts/` (≈340 KB total, no CDN). New `GET /assets/css/:name.css` and `GET /assets/vendor/fonts/:name.woff2` routes serve them.
- Web UI: theme toggle in the nav (☀︎/☾) — clicking flips `<html data-theme>` between `light` and `dark`, persists the choice in `localStorage` (`autodev-theme`). A synchronous boot script in `<head>` reads the stored value before any styles paint to prevent FOUC; if no value is stored it falls back to `prefers-color-scheme`. The button is wired via `data-action="toggle-theme"` and a delegated click handler to stay Phlex-2-safe (no inline `onclick`). Both icons are rendered; CSS hides the inactive one based on `data-theme`.
- Web UI: introduce the `Web::Views::Components::StatusPill` Phlex component (mirror of the design handoff's `primitives.jsx::StatusPill`). Pill = colored dot + localized label, sizes `sm`/`md`/`lg`, the dot pulses (`@keyframes pulse`) when the tone is `working` to convey live activity. The component carries the canonical AASM-state → `{label_key, tone}` mapping (16 entries, source: `primitives.jsx`).
- i18n: `Locales::WEB_TEMPLATES` now has one `web_status_*` key per AASM state (was 5 generic categories). Vocabulary refreshed to match the design handoff: `committing` → "Sauvegarde du travail" / "Saving work", `creating_mr` → "Création de la demande" / "Opening request", `done` → "Terminé" (no trailing -e) / "Done", `error` → "Échec — action requise" / "Failed — needs attention", etc. The old `web_status_active` umbrella key is gone.
- Web UI: every view now renders `render status_pill(state)` instead of the old `<span class="badge ...">` + `status_label`. Helper `status_pill(status, size:, with_dot:)` lives on `Web::I18nHelpers`, resolves the localized label, and returns a ready-to-render component. The `.badge-*` CSS bridge has been deleted from `app.css`. `Web::Helpers#status_class` removed (no callers left).
- Live updates: the SSE Turbo Stream sent on every transition now emits a real `StatusPill` HTML for the `status_<id>` target instead of the bare class-styled `<span>`. The wrapper `<span id>` keeps a flex layout so the pill's pulse animation has room to render.
- Web UI: dashboard rebuilt against the design handoff (`screen-dashboard.jsx` + `screenshots/01-dashboard-light.png`). New shape: sticky 240px sidebar (logo + theme toggle + lang switcher + bell, search-bar placeholder, 5 nav items with badges, "Nouveau ticket" CTA, user strip) → main column with topbar ("Bonjour 👋" greeting + Refresh/Nouvelle demande buttons) → 4-up KPI grid (En cours, À surveiller, En attente d'une réponse, Livrés cette semaine) → 2-col split (Demandes en cours card | Activité de la semaine sparkline + Vos projets card) → red error banner if any issue is in `error` / `needs_clarification`.
- Web UI: 8 new Phlex components covering the design system primitives — `Components::{Icon, Card, Button, IconButton, Logo, Kpi, Sparkline, Topbar, Sidebar}`. `Icon` ships 41 SVG paths (a verbatim port of `primitives.jsx::Icon`). `Button` carries 6 variants (primary/secondary/ghost/danger/danger_solid/ok_solid) × 3 sizes plus optional leading/trailing icons and an `href` mode that renders `<a>` instead of `<button>`. `Sparkline` takes an integer array; the rightmost bar is highlighted in `--accent-solid` to mark "today".
- Web UI: `Web::Views::Layout` and `Web::Views::Base` gain matching `nav:` and `shell:` kwargs. The dashboard renders with `nav: false, shell: false` (its sidebar replaces the global nav, its main column manages its own padding); other pages keep `nav: true, shell: true` so they stay centered in `.page-shell` until they get their own design pass.
- Web UI: real data feeds the new chrome — KPI counts come from `Helpers#dashboard_kpis` (active states sum, errors, needs_clarification, last 7 days `done`), the sparkline reads `weekly_activity_counts` from the `activity_events` table grouped by day, the projects list reuses `project_breakdown` and assigns each project a deterministic accent dot color from a 5-shade palette.
- i18n: 30+ new `web_*` keys for the dashboard chrome and KPIs (`web_dashboard_greeting`, `web_kpi_*`, `web_sidebar_*`, `web_dashboard_*_section`, `web_day_mon..sun`, `web_dashboard_error_banner_one/many`, `web_project_total_requests`, etc.). All in FR and EN. Sidebar nav labels use the design vocabulary: "Demandes" / "Requests" (`/issues`), "À surveiller" / "To watch" (`/errors`), "Conversations" + "Projets" placeholders.
- Responsive: the dashboard's KPI grid switches between 2 cols (mobile/tablet) and 4 cols (≥1024px); the split-grid stacks below 1024px. Mobile (<640px) hides the sidebar entirely — the mobile bottom nav from the JSX comes in a later task.
- Tests: existing dashboard assertions that referenced the old chrome (`'Dashboard'` heading, `'Toutes les issues'` link, `/list/X` href, "Issues actives" subheading, "Par projet" section) have been updated to assert against the new strings (`'Bonjour'` / `'Hello'`, `'Demandes en cours'`, `kpi-grid` class). Total suite: 436 tests, all green.
- Web UI: dashboard elements that point at features autodev doesn't ship yet (the chat/Conversations route, the global Projets index, the `/new` ticket-spec flow, search, notifications/bell) are now visually dimmed with `.coming-soon` (opacity 0.45, `pointer-events: none`, `title="Bientôt disponible"`). The two affected sidebar items (Conversations, Projets) also carry a small "Bientôt" / "Soon" pill badge in place of their count. Two new i18n keys (`web_coming_soon`, `web_coming_soon_tooltip`) carry the labels. The functional items (Tableau de bord, Demandes, À surveiller, Actualiser, theme/lang toggles) keep full opacity. Test in `web_server_test.rb` verifies the badge is rendered and counts ≥5 coming-soon markers on the dashboard.
- Web UI: new `GET /projects` index. Lists every project autodev tracks — both those configured in YAML (even with zero issues yet) and those that show up in the `issues` table — and renders a responsive card grid (1 / 2 / 3 columns at 768px / 1280px). Each card carries the deterministic accent mark + project path + GitLab repo URL + a 4-stat strip (Demandes en cours / À surveiller / Livrées ce mois / Total suivi) and links to `/projects/:slug`. Empty config shows a friendly "Aucun projet configuré pour le moment." state.
- Web UI: sidebar "Projets" item is no longer coming-soon — it now points at `/projects` with full opacity, and active-tab highlighting works when the user is on either the index or a specific project page.
- Helpers: new `all_known_projects` returns the deduplicated, sorted union of projects from the YAML config and from issue rows. Used by the index to surface configured-but-quiet projects before their first issue lands.
- Reloader: `Sinatra::Reloader.also_reload` now also covers `lib/autodev/web.rb` (the require_relative hub). Previously, adding a new view file under `web/views/` required a full restart because the hub wasn't being re-evaluated — the new file was watched but never `require`d. Future view additions now hot-reload like every other web file.
- i18n: 4 new keys for the index — `web_projects_index_title` / `_subtitle` / `_empty` and `web_projects_card_open`.
- Tests: 6 new cases in `web_projects_index_test.rb` covering DB-only projects, configured-only projects, topbar title, sidebar link reachability (no more `coming-soon`), per-card href to `/projects/:slug`, and the empty state. Total suite: 460 tests, all green.
- Web UI: `/projects/:slug` rebuilt against `screen-project.jsx` + `screenshots/06-project-light.png`. Same sidebar+topbar shell as the rest of the new chrome. Topbar carries a breadcrumb ("Projets › <path>"), the project path as title, the project's `extra_prompt` (or a fallback line) as subtitle, plus a "Voir sur GitLab" secondary button (linked when `gitlab_url` is in config) and a "Nouvelle demande" primary button rendered coming-soon. New tab bar with anchors (`?tab=…`) for: Vue d'ensemble (default), Demandes (with total count badge), Configuration Autodev, Équipe. Invalid tab values fall back to overview.
  - **Overview**: 1.5fr/1fr split. Left column = hero card (a colored "P" mark derived from the project path, name, GitLab URL, description, and a 4-stat strip — Demandes en cours / À surveiller / Livrées ce mois / Total suivi) + recent-requests card (top 5 with iid + title + relative time + status pill). Right column = "Détails techniques" KV card (default branch, extra_prompt summary truncated at 60 chars, post_completion summary) + "Équipe" coming-soon stub.
  - **Demandes**: dense list of all project issues with iid + title + relative time + status pill, full row clickable to the issue detail.
  - **Configuration**: 1.4fr/1fr split. Left = `.autodev.yml` viewer in a code-themed `<pre>` (`YAML.dump` of the project's config block) with a "Copier" coming-soon button. Right = "Comportement" + "Sécurité" placeholder cards (the toggles in the design need backend support that doesn't exist yet, so both are coming-soon stubs).
  - **Équipe**: full coming-soon stub with explanatory copy ("Synchronisation avec les membres GitLab à venir.").
- Helpers: new `project_overview_stats(project_path)` returning `{active, errors, done_month, total}` for the hero strip; this is distinct from the existing `project_stats(path)` used by the dashboard's "Par projet" table (different shape, different consumer). `project_dot_color` and `PROJECT_DOT_COLORS` were promoted from a private constant inside `Web::Views::Dashboard` to `Web::Helpers` so the project page can reuse the deterministic accent palette. New `gitlab_project_url(project_path)` helper.
- i18n: 28 new `web_project_*` keys (breadcrumb root, view-on-gitlab, no-description, four tab labels, four stat labels, recent section + view-all, technical-details section + branch/extra-prompt/post-completion KV labels and "unset" placeholders, team section + coming-soon copy, YAML title/copy/empty-block, behavior + security section titles, no-recent empty-state). FR + EN.
- Tests: 4 new cases — default tab is overview, overview renders stats grid, team tab is coming-soon stub, invalid tab falls back to overview. The existing `test_project_show_renders_app_config` was updated to navigate to `?tab=config` (the YAML lives there now, not on the default landing). Total suite: 454 tests, all green.
- Web UI: `/errors` rebuilt against `screen-errors.jsx` + `screenshots/03-errors-light.png`. Same sidebar+topbar shell. Page renamed "À surveiller" / "To watch" (the design's vocabulary). New shape:
  - Red banner with `web_errors_banner_one`/`web_errors_banner_many` count, body copy, and a "Tout marquer comme lu" button (coming-soon — autodev has no read-state concept yet).
  - Each errored issue rendered as a card with: header (iid mono / project / status pill / relative time on the right), bold title, business-language cause panel on a `--err-bg` tint with an icon box, native `<details>` + `<summary>` toggle revealing the technical stacktrace in a code block (`--code-bg/fg`), footer with avatar strip + "Voir le détail" button + a context-aware suggested action — "Réessayer maintenant" (POST `/issues/:id/reset`) for `error`, "Voir la question" (link to detail) for `needs_clarification`.
  - Cause + explanation pair derived from the row: `error_message` → "Échec technique" / "Une erreur a empêché autodev de continuer." / `needs_clarification` → "Question en attente" / "Autodev a posé une question…" / `post_completion_error` → "Erreur post-completion" / dedicated copy.
- i18n: 17 new `web_errors_*` keys (title/subtitle/banner one/many/body, mark-all-read, three cause/explain pairs, technical toggle, view-detail, retry, view-question, requester). Existing `web_errors_title` migrated from "autodev — Erreurs" to "À surveiller". `web_errors_none` text updated.
- Tests: 6 new cases in `web_server_test.rb` covering business-language cause selection, banner pluralization, `<details>` rendering, and the per-status action button. The locale tests asserting on `/errors` are updated to the new title strings. Total suite: 450 tests, all green.
- Web UI: `/issues` rebuilt against `screen-issues.jsx` + `screenshots/02-issues-light.png`. New chrome wraps the same shell as the dashboard (sidebar + topbar) and adds:
  - A filter bar with five tab pills (En cours / Échecs / Question en attente / Livrés / Tous), each with its own count badge tinted by tone (`err` / `warn` / muted). Tabs are real `<a>` links — submitting works without JS, and the `q=` search query is preserved when switching tabs.
  - An inline search field (the existing `q` filter) and a "Filtrer" button (marked coming-soon — the advanced-filter popover will land in a follow-up).
  - A new `tab=active|errors|waiting|done|all` URL parameter; default is `all`. Invalid values fall back to `all`.
  - Desktop: dense token-themed table with columns `# / Titre+project / Statut / Activité` (relative time). Mobile (<640px): the table hides and stacked `.issue-card` blocks take over.
- Helpers: `Web::IssuesFilter` gains `tab_param`, `apply_tab`, and `tab_counts` (5 cheap counts on the unfiltered dataset for the badges). `Web::I18nHelpers#relative_time(ts)` localizes deltas as "à l'instant" / "il y a 4 min" / "il y a 2 h" / "il y a 3 j" (and the EN equivalents).
- i18n: 16 new keys (`web_tab_*` x5, `web_issues_subtitle`, table headers, empty-state, relative-time templates).
- "Nouvelle demande" topbar button is rendered as `coming-soon` like on the dashboard — `/new` doesn't exist yet.
- Tests: 6 new cases in `web_issues_filter_test.rb` cover tab→status mapping (active / done / errors), default-and-invalid tab fallback to `all`, and the `q` query being preserved across tab links. The existing pagination assertions were updated to match the new pager rendering (`Page 1 / 2`) instead of the old combined "issue(s) — page X / Y" line. Total suite: 444 tests, all green.
- Dev quality-of-life: optional hot-reload for the web layer. Set `AUTODEV_WEB_RELOAD=1` in the environment and `Sinatra::Reloader` (from the new `sinatra-contrib ~> 4.0` dep) re-evaluates routes + Phlex views between requests when files under `lib/autodev/web/` or `lib/autodev/locales/` change. Off by default — production and the test suite are unaffected. The poller, worker pool, AASM model, and DB schema are NOT in the reload path; those still need a process restart. Documented in `bin/autodev` help and `CLAUDE.md`.

## [0.11.6] - 2026-04-20

### Fixed

- Follow-up on the v0.11.5 single-connection switch: workers were hitting `Sequel::PoolTimeout: timeout: 5.0` because Sequel's default pool timeout is 5s. With `max_connections: 1`, any caller mid-iteration on a dataset holds the connection through the entire loop (SQLite keeps the cursor open across `.each`), and if the loop body does slow external I/O — as `poll_unassignment` and `poll_done_unassigned` do, with GitLab API calls per issue — workers waiting for the connection blow through 5s.
  - Raised `pool_timeout` to 60s for SQLite.
  - Materialized the two `poll_unassignment`/`poll_done_unassigned` iterations with `.all.each` so the DB connection is released before GitLab calls run. Applied the same shape defensively to `poll_pipelines` / `poll_discussions` for consistency, though their loop bodies only enqueue (fast).
- Startup log now includes `pool_timeout` alongside `journal_mode`/`busy_timeout`/`max_connections` so the effective pool config is visible without re-instrumenting.

## [0.11.5] - 2026-04-20

### Fixed

- SQLite `database is locked` errors are finally gone. The v0.11.2–v0.11.4 attempts relied on Sequel's `after_connect` hook to apply per-connection PRAGMAs/busy_handler to every pooled connection; in practice the hook did not fire in our setup (confirmed in logs: `busy_timeout=0ms` at startup, no `[DB-LOCK]` dumps under contention), which is why increasing timeouts and adding defensive handlers changed nothing. Switched to `max_connections: 1` so Sequel's `ThreadedConnectionPool` serializes all DB access through a Ruby mutex. For SQLite this is strictly better: writes are already serialized at the file level, so multiple pool connections only add contention (and trigger `BusyException` when writers collide). `journal_mode=WAL` and `busy_timeout=30000` are now applied directly to the single connection via `@db.run`. Startup logs the effective values so they're visible without re-instrumenting.
- Dropped the unused `after_connect`, `busy_handler`, and thread-backtrace dump code added in v0.11.3–v0.11.4 — the root-cause fix makes them moot.

## [0.11.4] - 2026-04-20

### Added

- SQLite `busy_handler` now dumps all thread backtraces to stderr after 20 retries on the same contention episode (prefixed `[DB-LOCK]`). Since the handler runs in the thread that is waiting for the lock, the dump captures what every other thread is doing at the exact moment of contention — making it possible to identify which operation is holding the write lock. Diagnostic only; does not change the retry policy.

## [0.11.3] - 2026-04-20

### Fixed

- Follow-up on the v0.11.2 SQLite lock fix: 5s `busy_timeout` was still being exceeded under real-world contention (3 workers + poller all writing). Bump to 30s and add a Ruby-side `busy_handler` as a safety net in case the PRAGMA is silently ignored on some connection. Also log the effective `busy_timeout` at startup so the applied value is verifiable from the autodev output.

## [0.11.2] - 2026-04-20

### Fixed

- SQLite `busy_timeout=5000` PRAGMA is now applied to every connection in the pool via Sequel's `after_connect` hook, not just the first one. `busy_timeout` is per-connection, so under worker contention the other pool connections were falling back to the default (0) and raising `SQLite3::BusyException: database is locked` immediately instead of waiting for the writer lock.

## [0.11.1] - 2026-04-14

### Changed

- Usage checker now runs `danger-claude -p` instead of calling the Anthropic API directly — uses the same Docker environment and auth as the rest of autodev. No API key needed.

## [0.11.0] - 2026-04-14

### Added

- Proactive Claude usage check before each poll cycle. Skips the cycle if the account is rate-limited. Result is cached for 5 minutes.

## [0.10.2] - 2026-04-14

### Fixed

- Pipeline monitor now checks MR state before dispatching — if the MR is merged or closed, the issue transitions to `done` immediately instead of attempting mr-review on a branch that no longer exists.

## [0.10.1] - 2026-04-13

### Fixed

- Fix `CLEAN_ENV` constant resolution in `PipelineMonitor::Reviewer` and `IssueProcessor::MrManager` — fully qualify as `DangerClaudeRunner::CLEAN_ENV` (same bug previously fixed in `PostCompletion`). Was causing non-fatal `uninitialized constant PipelineMonitor::Reviewer::CLEAN_ENV` errors that skipped mr-review on every green pipeline.
- Activity log timestamps now include the date (`MM-DD HH:MM`) and use the host's local timezone instead of UTC. Previously logs spanning multiple days were ambiguous (just `HH:MM`) and times were displayed in UTC even though the autodev host runs in CEST.
- On reentry (`done` → `pending` when `label_todo` is re-applied), the `activity_note_id` is now reset so a fresh activity log comment is created at the bottom of the issue thread. Previously the existing activity log was edited in place, leaving it stranded above any user comments posted between the two runs and giving the impression that autodev was idle.

## [0.10.0] - 2026-04-10

### Changed

- Renamed `label_mr` config key to `label_done` (internal rename, GitLab label value unchanged). The old `label_mr` key is now deprecated with a warning.

### Added

- Localized notification comment posted on the issue when autodev finishes normally (`done_nominal`): explains how to relaunch autodev or move on.
- Localized notification comment posted on the issue when a question/investigation is complete (`done_question`): explains how to go further or request an implementation.

## [0.9.1] - 2026-04-10

### Fixed

- Pipeline fixer now checks `git log` output content (not just exit status) to detect new commits before pushing, matching the correct pattern already used in MrFixer.
- Legacy status migration no longer resets legitimately `done` issues with an MR back to `checking_pipeline` on every startup. Only the extinct `mr_fixed` status is migrated.
- Branch names with slashes no longer create nested subdirectories in `/tmp` for context files.

### Changed

- Extracted `default_branch`, `push_with_lease_fallback`, and `safe_mark_failed!` into `DangerClaudeRunner` to eliminate duplication across `IssueProcessor`, `MrFixer`, and `PipelineMonitor`.

### Added

- `pickup_delay` config (default 600s): prevents processing issues created less than N seconds ago, giving authors time to finalize specs.
- `stagnation_threshold` config (default 5): consecutive identical failures before marking an issue as done with an alert.
- `Reviewer` module in PipelineMonitor: runs `mr-review` after the first green pipeline instead of immediately after MR creation. Review count incremented only on successful execution. Hard limit of 3 review rounds.
- Stagnation detection for both pipeline failures (SHA256 of failed job names) and unresolved discussions (SHA256 of discussion IDs). Replaces `max_fix_rounds`.
- Unassignment detection: active issues no longer assigned to autodev transition to `done` at the next poll cycle.
- `post_completion` now triggers when autodev is unassigned from a `done` issue (instead of immediately after pipeline green). Skipped if MR is already merged or closed.
- Reentry: `done` issues with `label_todo` detected at poll time transition back to `pending` via `reenter!`, resetting stagnation signatures and review count.
- New DB columns: `review_count` (INTEGER DEFAULT 0), `stagnation_signatures` (TEXT, JSON).
- Per-project `app:` config block with optional `setup`, `test`, and `lint` subsections. Each subsection accepts a list of commands (Docker CMD format) that are passed to danger-claude prompts as environment-specific instructions. Validated at boot with clear error messages.
- `AppInstructions` module: formats `app:` config into a prompt section injected in all danger-claude prompts (implementer, split/parallel, pipeline fixer, MR fixer). Instructions are marked as taking priority over CLAUDE.md and skills.
- `app.run` config: list of background server commands with optional `port` for Docker port exposure. Ports are dynamically allocated on the host via `PortAllocator` and mapped to container ports. Resolved URLs (`http://localhost:<host_port>`) are injected into prompts for Chrome DevTools access.
- `PortAllocator` module: allocates ephemeral host ports via `TCPServer` and generates danger-claude `-P` args for Docker port mappings.
- `ScreenshotUploader` module: reads screenshot index written by Claude in the shared `/tmp` directory, uploads each PNG to GitLab via `client.upload_file`, and posts a formatted comment on the issue. Supports `mr_fix` context annotation. Integrated after implementation and after MR discussion fixes.
- Screenshot prompt instructions injected when `app.run` is configured: tells Claude to capture impacted pages after implementation, save PNGs with an `index.json` manifest in a shared directory.

### Changed

- **State machine overhaul (v0.10)**: terminal state renamed from `over` to `done`. `blocked` state removed entirely — infrastructure failures and canceled pipelines now stay in `checking_pipeline` until manual intervention or natural resolution.
- **Review after pipeline**: `mr-review` now runs after the first green pipeline instead of immediately after MR creation. `mr_created!` transitions directly to `checking_pipeline` (no intermediate `reviewing` step).
- **Polling by assignee**: replaced `trigger_label`-based polling with `assignee_id`-based polling filtered by `labels_todo`.
- **3 labels only**: simplified label workflow to `labels_todo`, `label_doing`, `label_mr`. Label stays `label_doing` during the entire cycle and switches to `label_mr` only on `done`.
- Chrome DevTools is now auto-enabled when any project has `app.run` entries with exposed ports. The `chrome_devtools` config flag has been removed — Chrome and MCP injection are managed automatically.

### Removed

- `blocked` state and all associated label management (`label_blocked`, `apply_label_blocked`).
- `trigger_label` config (replaced by assignee-based polling).
- `max_fix_rounds` config (replaced by stagnation detection).
- `label_done` and `label_blocked` config fields (deprecated with warnings).
- `labels_to_remove` / `label_to_add` deprecated config fields.
- `pipeline_failed_infra!` and `pipeline_canceled!` events.
- `resume_todo!` and `resume_mr!` events (replaced by `reenter!`).
- `review_complete!` event (replaced by `review_done!`).

### Fixed

- Fix `new_commits?` in MrFixer always returning true: `git log` exits 0 even with empty output, so the check must verify output is non-empty. Previously `finalize_no_commits` was dead code — the push path was always taken even when discussion fixes produced no changes.
- Fix misleading log message in `finalize_green_done`: always said "no discussions" regardless of actual discussion count.
- Fix port allocation TOCTOU race in `PortAllocator`: hold `TCPServer` sockets open until the consuming subprocess has started, preventing the OS from reassigning the port between allocation and Docker bind.

### Changed

- Replace `WorkerPool` busy-polling (`pop(true)` + `sleep 0.5`) with blocking `Queue#pop`. Idle workers now sleep on the queue instead of polling at 2Hz. Shutdown uses `nil` sentinels to unblock threads.

## [0.9.0] - 2026-04-07

### Added

- **GitLab activity log**: each issue now gets a single, continuously updated comment that tracks every autodev action in real time — processing start, clone, spec check, implementation, push, MR creation, review, pipeline checks, discussion fixes, errors, retries, resume events, and polling. Localized in French and English (41 activity templates per locale). Powered by a new `ActivityLogger` module with both instance (`log_activity`) and class (`ActivityLogger.post`) entry points, and `activity_note_id` / `pipeline_poll_since` columns. Pipeline polling lines are compacted: repeated checks update a single line showing the time of the first poll (`🔍 Polling pipeline status since 18:20...`) instead of creating a new line per cycle. Resume events (`resume_todo`, `resume_mr`) are now logged when an issue re-enters the processing pipeline after human intervention.
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

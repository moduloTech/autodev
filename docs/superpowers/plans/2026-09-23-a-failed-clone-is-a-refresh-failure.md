# Plan — a failed clone is a refresh failure (Autodev #117)

Spec: `docs/superpowers/specs/2026-09-23-a-failed-clone-is-a-refresh-failure-design.md`
Branch: `fix/117-a-failed-clone-is-a-refresh-failure` off `origin/master`.
Test: `mise x ruby@4.0.1 -- bundle exec rake test`; one file:
`mise x ruby@4.0.1 -- bundle exec ruby -Itest <file>` (every file must pass alone).
Lint: `mise x ruby@4.0.1 -- bundle exec rubocop <files>`.
Baseline: 2599 runs, 5301 assertions, 0 failures.

## Frozen contract

### `Autospec::ProjectBriefer` (`app/services/autospec/project_briefer.rb`)

- `include ProcessRunner`; `initialize` sets `@dc_stdout = +''`, `@dc_stderr = +''`
  (ProcessRunner's record buffers; never persisted by the briefer).
- `DANGER_CLAUDE_TIMEOUT = 10 * 60`.
- Public surface unchanged: `refresh!`, `RefreshFailed`, `stub_invoker`, `PROMPT`,
  `CLONE_DEPTH`. `refresh!` still rescues only `RefreshFailed`, stores, re-raises.
- Private `external!(label) { … }`: yields; `rescue SystemCallError => e` →
  `raise RefreshFailed, Redactor.scrub("#{label} could not run: #{e.message}")`.
- Git calls: `ShellHelpers.run_cmd_status(cmd)` → `[out, err, ok(Boolean)]`, each
  inside `external!`.
  - `pick_branch`: `ls-remote --heads <url> staging`; `!ok` → `RefreshFailed`
    `"git ls-remote (staging) failed: <err[0,400]>"`; ok + non-empty → `'staging'`;
    ok + empty → `default_branch`.
  - `default_branch`: `ls-remote --symref <url> HEAD`; `!ok` → `RefreshFailed`
    `"git ls-remote (HEAD) failed: <err[0,400]>"`; ok → regex, else `'main'`.
  - `run_git_clone!`: `!ok` → `RefreshFailed` `"git clone (<branch>) failed: <err[0,400]>"`.
- danger-claude: `run_with_timeout('danger-claude', ['-p', PROMPT], chdir: work_dir,
  label: 'briefing', timeout: DANGER_CLAUDE_TIMEOUT)` inside `external!('danger-claude')`,
  plus `rescue ImplementationError => e` → `RefreshFailed, e.message` (timeout).
  Not ok → `RefreshFailed "danger-claude failed (<how>): <detail>"` where
  `<how>` = `exit N` or `signal N` from the 4th element, `<detail>` = stripped
  stderr tail (400) if non-empty, else stripped stdout tail (400), else
  `no output`. Empty success output → unchanged `'danger-claude returned empty output'`.
- All `RefreshFailed` messages are `Redactor.scrub`bed.

### `Autodev::HealthReport` (`app/services/autodev/health_report.rb`)

- `CHECKS` gains `:project_briefings` (appended last).
- `BRIEFING_STALE_AFTER = 6 * 3600`.
- `check_project_briefings`:
  - `@poller_expected` false → `:ok`, detail `'briefing refresh not scheduled here'`.
  - no project → `:ok`, `'no projects'`.
  - stale = `Project` rows whose `COALESCE(briefing_generated_at, created_at) < @now - 6h`.
  - none stale → `:ok`, `"#{n} briefing(s) fresh"`, meta `{ count:, stale_after_seconds:, failing: }`
    where `failing` = rows with a non-blank `briefing_error`.
  - some stale → `:warn`, `"#{k} project briefing(s) not refreshed for over 6h"`,
    meta adds `sample:` first 5 as `"<gitlab_path> (<age>h[: <briefing_error[0,120]>])"`.
- i18n: `web_admin_health_check_project_briefings` in `config/locales/web.{fr,en}.yml`.

## Tasks

### Lane A — briefer (files: `app/services/autospec/project_briefer.rb`,
`test/services/autospec/project_briefer_test.rb`)

Tests to write first (red on master):

1. A clone that exits non-zero raises `RefreshFailed` whose message contains git's
   stderr, and `briefing_error` stores it. (Today: `Errno::ENOENT`.) Stub
   `Open3.capture3` per argv: ls-remote ok, clone → `FakeStatus(false)` with
   stderr `"fatal: unable to access …"`; danger-claude must **not** be called
   (stub_invoker raises if reached).
2. `ls-remote --heads` failing raises `RefreshFailed` naming `ls-remote`, no clone attempted.
3. `ls-remote --heads` ok + empty → `default_branch` is consulted; `--symref` output
   `ref: refs/heads/master\tHEAD` → clone receives `--branch master`.
4. `--symref` failing → `RefreshFailed` naming `ls-remote (HEAD)`, no clone of `main`.
5. A spawn `Errno::ENOENT` (git missing) → `RefreshFailed` naming the command; stored.
6. danger-claude path (stub_invoker nil; clone stubbed ok; `run_with_timeout` stubbed):
   non-zero with empty stderr and stdout `"boom"` → message contains `boom` and `exit 1`.
7. `ImplementationError` from `run_with_timeout` (timeout) → `RefreshFailed`, stored.
8. danger-claude is spawned with `timeout: DANGER_CLAUDE_TIMEOUT` and
   `DANGER_CLAUDE_TIMEOUT == 600` — and through `ProcessRunner#spawn_process` (so
   `CLEAN_ENV` applies): assert `Process.spawn` receives an env hash with
   `'GEM_HOME' => nil`.
9. The stored message is scrubbed: stderr containing `https://oauth2:t0k3n@host` is
   stored as `oauth2:***@`.
10. A non-`RefreshFailed` error (e.g. `store_success!` raising) is **not** stored and
    propagates unchanged (the chosen direction).
11. The existing `bypass_clone` fixture returns `FakeStatus(true)`, which is truthy
    whatever it says — replace it with a real-boolean path (`FakeStatus` answering
    `success?`, consumed through `run_cmd_status`) so the happy-path tests would go
    red if the guard died again.

### Lane B — health (files: `app/services/autodev/health_report.rb`,
`test/services/health_report_project_briefings_test.rb`, `config/locales/web.{fr,en}.yml`)

1. `:project_briefings` ∈ `CHECKS`; i18n derived test passes (existing).
2. fresh (generated 1h ago) → ok; generated 7h ago → warn with sample naming the path.
3. boundary: 5h59 → ok, 6h01 → warn.
4. never generated, created 1h ago → ok; created 7h ago → warn.
5. stale + `briefing_error` → sample carries the error; fresh + error → ok, `failing: 1`.
6. `poller_expected: false` → ok even with a 2-day-old briefing.
7. warn keeps `/healthz` at 200 (integration, as `HealthReportMrReviewTokenTest`).

### Me — integration

CHANGELOG `[Unreleased]`, CLAUDE.md (Error Handling row + health list), technical
usage doc row, full suite, rubocop on touched files, sabotage, reviews.

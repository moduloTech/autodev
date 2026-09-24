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
- All `RefreshFailed` messages are `Redactor.scrub`bed **before** any truncation:
  scrub the whole stream, then cut (`Redactor.scrub(err)[0, 400]`, tail likewise).
  Cutting first can split a credential before its `@` and `URL_CREDENTIALS` then
  misses it (plan adversary, verified).

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

## Plan adversary — "would stay green" list, each assigned

Every row below is a test to write; the lane owning the file writes it.

Lane A (`test/services/autospec/project_briefer_test.rb`, new
`test/jobs/refresh_project_briefings_job_test.rb`):

- A1 guard live: clone stub `['', 'fatal: x', FakeStatus(false)]`, stub_invoker
  **`flunk`s** (never `raise RefreshFailed`) → `RefreshFailed` `/fatal: x/`, stored
  `/git clone \(main\) failed: fatal: x/`. Success fixtures cannot prove the guard; item 11
  above is replaced by this. Dispatch stubs on argv content (`include?('--heads')`),
  never `args[0]` — `run_cmd_status` passes the env Hash `{}` first.
- A2 `--heads` fails → message `/ls-remote \(staging\)/`, `--symref` flunks, no clone argv.
- A3 `--heads` ok non-empty → clone argv has `--branch staging`, `--symref` flunks.
- A4 `--symref` ok without `ref:` → clone `--branch main`; with `ref: refs/heads/master\tHEAD` → `master`.
- A5 `--symref` fails → `/ls-remote \(HEAD\)/`, no clone.
- A6 git missing (`Errno::ENOENT` from capture3) → `RefreshFailed` naming git, stored.
- A7 danger-claude spawn ENOENT, **real `run_with_timeout`**: stub_invoker nil, clone
  stubbed ok (creates no dir) → `/danger-claude could not run: No such file or directory/`, stored.
- A8 real child: tmpdir with executable fake `danger-claude` prepended to PATH, clone
  stub `FileUtils.mkdir_p(args.last)` → `briefing_text == '# briefing'` (proves
  `@dc_stdout`/`@dc_stderr` are mutable buffers). Second script `exit 3` with
  stderr empty, stdout text → message has `exit 3` and the stdout.
- A9 timeout, real child: fake `sleep 30`, `DANGER_CLAUDE_TIMEOUT` stubbed to 1 →
  `/timed out after 1s/`, stored. (~6 s: kill grace.)
- A10 `signal N`: a status with `exitstatus nil, termsig 9` → `/signal 9/`, no `/exit/`.
- A11 detail precedence: stderr `E` + stdout `O` → E only; stdout `'a'*600+'END'` →
  ends with END, ≤400; both blank → `/\): no output\z/`.
- A12 empty success output → message == `'danger-claude returned empty output'`.
- A13 scrub before cut: `'x'*370 + 'fatal: https://oauth2:s3cr3tt0k3nABCDEFGH@host/g/p.git'`
  on clone stderr, on ls-remote stderr, and on the danger-claude stdout tail → stored
  error never includes `s3cr3t`.
- A14 `Dir.mktmpdir` raising `Errno::ENOSPC` propagates as ENOSPC, nothing stored.
- A15 `store_success!` raising a non-RefreshFailed propagates unchanged, not stored.
- A16 `DANGER_CLAUDE_TIMEOUT == 600`; the spawn goes through `CLEAN_ENV`
  (`Process.spawn` receives an env with `'GEM_HOME' => nil`).
- A17 job: two projects, clone fails for the first → first has `briefing_error =~ /git clone/`,
  second `briefing_text == 'ok'` after `perform_now`. Reverse: a `RecordInvalid`
  from `store_success!` propagates out of `perform_now`.

Lane B (`test/services/health_report_project_briefings_test.rb`):

- B1 `/healthz/project_briefings` stays 200 with body `warn` on a 7 h-old briefing —
  **with `poller_expected: true` forced** (wrap `HealthReport.new`); in test
  `Rails.env.local?` is true, so the default constructor hits the "not scheduled" ok.
- B2 staleness reads `COALESCE(briefing_generated_at, created_at)`, not `updated_at`:
  `created_at: 7.hours.ago` then `update!(briefing_error: 'x')` → warn; same for
  `briefing_generated_at: 7.hours.ago` with a fresh `updated_at`.
- B3 counts: 7 projects, 6 stale → detail starts `"6 project briefing(s)"`,
  `sample.size == 5`, `meta[:count] == 7`; a 300-char error shows exactly 120.
- B4 boundary: exactly 6 h → ok (strict `<`).
- B5 fresh + error → ok, `failing: 1`; `poller_expected: false` → ok on a 2-day-old briefing.

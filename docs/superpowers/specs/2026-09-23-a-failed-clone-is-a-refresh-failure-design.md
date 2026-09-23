# A failed clone is a refresh failure (Autodev #117)

Date: 2026-09-23
Ticket: Skynet Autodev #117 — "Le garde-fou du clone de briefing ne se déclenche
jamais : un clone raté devient une ENOENT sans cause, et l'erreur n'est stockée
nulle part"

## Problem

`Autospec::ProjectBriefer` (`app/services/autospec/project_briefer.rb`) is the only
service in the repository that calls `Open3.capture3` directly, and three of its
four call sites read the third return value as a boolean:

```ruby
_out, err, ok = Open3.capture3(*cmd)
raise RefreshFailed, "git clone (#{branch}) failed: …" unless ok
```

That value is a `Process::Status`, which is always truthy. Measured under the
production Ruby (4.0.1): `Open3.capture3('false')` → `[Process::Status, success?
false, truthy]`. The guard is dead, a failed clone passes for a success, and the
next spawn — danger-claude with `chdir:` the directory the clone never created —
raises `Errno::ENOENT` naming a temp path. git's stderr, which held the cause,
was captured and discarded.

`refresh!` rescues only `RefreshFailed`, so the ENOENT is never stored in
`projects.briefing_error`. The job (`RefreshProjectBriefingsJob#refresh_one`)
also rescues only `RefreshFailed`, so the ENOENT **aborts the whole
`find_each`**. Measured in the production log: on 2026-09-02 at 14:00 and
15:00, 2026-09-05 at 20:00 and 2026-09-06 at 09:00, the job failed after ~8 s on
`powerpanne/core` (the first project) and `ff/fast/core` has no log line at all
for those runs — it was never attempted. The ticket did not name this
consequence.

Three further facts measured while reading the ticket:

1. **`briefing_error` is read by nothing.** No view, no health check, no job —
   `grep -rn briefing app lib config` finds only the writer and the system prompt,
   which reads `briefing_text`. So even a correctly stored error is silent.
2. **`DANGER_CLAUDE_TIMEOUT` is declared and never applied.** The raw
   `capture3` has no timeout (`lib/autodev/danger_claude_runner.rb:104` says so).
   A hung danger-claude holds a Solid Queue worker thread indefinitely.
3. **Every stored danger-claude failure in production is empty**:
   `Briefing refresh failed for …: danger-claude failed: ` — danger-claude wrote
   nothing on stderr, and only stderr was kept.

The two `ls-remote` calls (`pick_branch`, `default_branch`) make the same
mistake. They cause no visible damage because a failed `ls-remote` prints nothing
on stdout, so `pick_branch` falls through to `default_branch`, which falls
through to `'main'`, and the clone of `main` then fails. That hides the real
cause (the network) behind a wrong one ("Remote branch main not found" on a
`master` repository).

## Measurements

| Question | Answer | How |
|---|---|---|
| Is `Process::Status` truthy on failure? | Yes | `ruby -ropen3 -e 'p Open3.capture3("false")[2] ? 1 : 0'` under ruby@4.0.1 |
| Does git's clone stderr carry the PAT from `https://oauth2:<token>@…`? | No — git 2.50.1 anonymises the URL on connection refused, DNS failure and auth failure | Three probes against a fake token; prod runs the same git 2.50.1 (Apple Git-155) |
| Did the ENOENT skip the next project? | Yes, 4 runs out of 8 failed ones, see above | prod `production.log.2026090{4,6,8}-*` |
| How long does one refresh take? | Clone + danger-claude over 713 successful `powerpanne` runs: p50 99 s, p99 155 s, **max 279 s**; `fast`: max 111 s | Job start (`Performed … in Xms` minus duration) to the project's `Refreshed briefing` line |
| How long can a briefing go without a successful refresh? | Gaps between two successful refreshes, 2026-08-21 → 2026-09-23, per project: 99 % ≤ 2 h; the unexplained noise (night hours) tops out at **5.6 h**; the three real incidents are **9.1 h** (28/08, danger-claude failing hourly), **10.1 h** and **12.9 h** (the Docker outage of 02-03/09) | same log, 1 427 `Refreshed briefing` lines |

## Decisions

### 1. Read the status, not the object — at every site

Git calls go through `ShellHelpers.run_cmd_status`, which is what the rest of the
repository uses and returns `status.success?` as a real boolean. A failed
`ls-remote` now raises `RefreshFailed` with git's stderr instead of guessing a
branch: it says nothing about whether `staging` exists. A *successful*
`ls-remote --heads … staging` with empty output (exit 0) still means "no staging
branch", and a successful `--symref` with no `ref:` line still falls back to
`main`.

### 2. Wrap the external calls; do not widen the rescue

The ticket asks to choose between widening `refresh!`'s rescue and wrapping the
external calls so they can only produce `RefreshFailed`. **Wrap.** One private
helper runs every external command and converts a `SystemCallError` raised by the
spawn itself (git or danger-claude missing, a vanished `chdir:`) into a
`RefreshFailed` that names the command. So `RefreshFailed` keeps one meaning —
"this refresh failed for a reason outside autodev" — and it is the only thing
`refresh!` and the job rescue. A genuine bug (`NoMethodError`, a failed
`update!`) still escapes both and lands in Solid Queue's failed executions, which
is where a bug belongs; widening the rescue would have filed bugs under
`briefing_error` next to network outages. The job's rescue is left alone for the
same reason.

`Dir.mktmpdir` is outside the wrapper on purpose: a full disk is not a briefing
problem.

Every `RefreshFailed` message goes through `Redactor.scrub`, like
`ShellHelpers.run_cmd`'s. git 2.50.1 already anonymises the URL (measured), so
this is defence in depth against another git build, not a fix for a leak.

### 3. danger-claude runs through `ProcessRunner`

The briefer includes `ProcessRunner` and calls `run_with_timeout` instead of
`capture3`. This gives it, in one move, the three properties every other
danger-claude call already has: the timeout (TERM the process group, then KILL),
`DangerClaudeRunner::CLEAN_ENV` (the briefer was the one child that inherited
autodev's Bundler variables, Autodev #77), and the `Process::Status` as the
fourth element for the failure message. A timeout (`ImplementationError` from
`handle_timeout`) becomes a `RefreshFailed`.

`DANGER_CLAUDE_TIMEOUT` goes from 300 s to **600 s**. The declared 300 s was
never enforced, and the measured maximum of 279 s for clone *plus* danger-claude
leaves it a 21 s margin. 600 s is about twice the observed maximum, so the cap
catches a hang without failing any refresh that succeeds today. The briefer does
not read the per-project `dc_timeout`: that setting sizes implementation calls
and feeds `HealthReport#longest_worker_timeout`, and a briefing is neither.

### 4. A failure message that says something

When danger-claude fails, the message is built from stderr, else the tail of
stdout, plus how the process ended (`exit N` / `signal N`). Every production
failure so far stored an empty string after the colon.

### 5. The signal: a `project_briefings` health check

New check in `Autodev::HealthReport::CHECKS`, so it shows on `/healthz` and
`/admin/health` (card title `web_admin_health_check_project_briefings`, fr + en).

- **Stale** = the last successful refresh (`briefing_generated_at`, or the
  project's `created_at` when it never had one) is older than
  `BRIEFING_STALE_AFTER = 6 h`. The measured noise floor is 5.6 h and the
  smallest real incident is 9.1 h, so 6 h flags all three incidents and none of
  the noise. Fixed, not configurable — same ruling as the `gitlab_requests`
  windows: an observability figure nobody tunes.
- **`warn`, never `down`.** A stale briefing degrades AutoSpec's context; it
  stops no delivery. `/healthz` keeps answering 200 (MonitoringController maps
  only `down` to 503).
- **Staleness, not `briefing_error`, raises it.** One failed hourly run with a
  fresh previous briefing is the noise the calibration excludes. `briefing_error`
  is carried in the meta sample so the card names the cause.
- **Not expected where recurring jobs do not run.** `config/recurring.yml`'s
  `development:` block is empty, so in a local env every briefing is stale by
  construction. The check reuses `HealthReport`'s existing `poller_expected`
  flag (default `!Rails.env.local?`), which states exactly that.

## Out of scope

- The underlying network intermittence of 02-06/09 (Autodev #96).
- Rendering `briefing_error` on the project page: the health check is the signal
  chosen for this ticket.
- The same `capture2` shape elsewhere: `ChromeDevtoolsInjector`, `BootGuard`,
  `ChromeLauncher` and `Reviewer` already name the second value `status` and read
  `success?` (grep, `lib/`).

# Autodev #127 — a weekly limit is a quota, not a failure

No design spec: the change adds no table, column or public surface. The rule it
changes (which danger-claude wordings mean "quota exhausted", and how a reset
date is read) is recorded in `RateLimitDetector`'s comments and in `CLAUDE.md`'s
Error Handling table.

## Measured (production, 2026-09-28)

- Wordings that reached autodev (`issues.error_message` / `dc_stdout`,
  `activity_events.payload_json`), all `· resets … (UTC)`:
  - `You've hit your limit · resets 7pm (UTC)` / `4:40pm`
  - `You've hit your session limit · resets 4:30am (UTC)`
  - `You've hit your weekly limit · resets 3am (UTC)` (A#68, 2026-09-24)
  - `You've hit your weekly limit · resets Oct 1, 3am (UTC)` (A#137, #142, #144, #145, 2026-09-26)
- Claude Code 2.1.283 binary also carries `hit your fast limit`,
  `hit your monthly spend limit`, `hit your monthly limit`, and a templated
  `hit your ${h}`.
- The unrecognised weekly wording sent 5 rows through the generic failure
  handlers: `error`, `next_retry_at` NULL, public `echec correction MR` /
  `echec de la correction du pipeline` comments on PP#14856 (2026-09-24),
  #16030, #14007, #16269, #16423. DormantAudit revived them into the same limit;
  A#142, #144 and #145 reached `dormant_exhausted` that way (A#68 got past the
  3am reset and was exhausted later, on docker_build timeouts).
- Every usage probe still on record (1014, the oldest kept 2026-09-27 04:46 —
  the start is past retention) classified `broken` (`danger_claude` card down,
  `claude_usage` ok).
- The probe spawns with no `chdir`, so from the LaunchAgent's
  `WorkingDirectory` `/Users/modulotech`: danger-claude mounts the service
  account's home into the container, and mise inside reads
  `~/.config/mise/config.toml` as an untrusted project config. Claude still
  answered (the weekly message is its `result`), so the mise error is noise —
  but the probe has no business mounting the home that holds
  `~/.autodev/config.yml`.

## Decisions (owner, 2026-09-28)

- Keep the existing quota park (`error` + `next_retry_at` = reset, no comment,
  `retry_count` untouched, invisible to DormantAudit's error arm while the
  budget is not already spent — see Out of scope). The defect is the
  non-recognition only.
- The false public failures get a reply comment after the fix (the owner
  ruled on four; the truthfulness review found a fifth, PP#14856).

## Changes

1. `RateLimitDetector::PATTERN`: `you['’]ve hit your (?:[\w'’-]+ ){0,3}limit`
   (any one- to three-word qualifier, apostrophes allowed: session, weekly,
   fast, monthly spend, org's monthly spend…) plus the existing `rate limit` /
   `usage limit`. `UsageChecker` inherits it. Revised after review: the
   binary's `org's` / `channel's monthly spend limit` are three words.
2. `RateLimitDetector::RESET_PATTERN`: optional `Mon D,` date before the hour.
   `parse_reset_time(text, now: Time.now.utc)`:
   - hour-only: unchanged (today, +1 day when past);
   - dated: `now.year`; if that is more than one day in the past, `now.year + 1`
     (a December message naming January). A date just passed (clock skew,
     latency) stays this year → `wait_seconds` floors at 60s, never a year's pause;
   - an unknown month name or an impossible day (`Feb 30`) → `nil` (the 3600s
     default), never a silently normalised date.
   - The `RateLimitError` message shows the date when the reset is ≥ 24h away.
3. `UsageProbeSpawn#send_probe`: run the probe in one stable directory,
   `/tmp/autodev-usage-probe`, emptied before each probe, not in the process
   cwd. Stable rather than one per probe (revised after the adversarial
   review): Claude Code keys `~/.claude/projects/<cwd>` on the cwd, in the
   persisted danger-claude volume.
4. Revised after review: an impossible 12-hour time reads as no reset instead
   of raising `ArgumentError`, and a dated reset may be last year's (a
   "Dec 31" read on January 1st).

## Tests

- Detector: every measured wording raises; the dated reset parses to
  2026-10-01 03:00 UTC from 2026-09-28; year rollover; just-passed date stays
  this year; bad month / impossible day → nil reset; message carries the date.
- UsageChecker: the verbatim weekly probe output (incl. the mise lines, exit 1)
  reads `quota_exhausted`; the probe's cwd is an empty directory that is not
  `Dir.pwd` and is gone afterwards.
- End to end (A#144's path): a `fixing_discussions` row whose danger-claude call
  returns the weekly envelope and exits non-zero ends in `error` with
  `next_retry_at` = 2026-10-01 03:00 UTC, no `mr_fix_error` notification, a
  `rate_limit` activity; same for the PipelineMonitor fixer (A#137's path) and
  IssueProcessor.

## Out of scope

- `Autospec::ProjectBriefer` calls danger-claude without `check_dc_failures!`.
- The `activity_rate_limit` line shows the wait in seconds (≈ 242000s for a
  weekly reset).
- Any detector match on a *successful* run's text (`rate limit` in a summary)
  is pre-existing.
- A row parked on a quota with `retry_count > max_retries` stays a DormantAudit
  error-arm candidate (`dormant_audit.rb:129`), so it is re-armed into the limit
  once. Found by the plan review; a #103 rule, left for the owner.

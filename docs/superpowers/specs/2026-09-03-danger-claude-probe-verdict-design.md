# The probe that already exercises `danger-claude` keeps only one of its verdicts (Autodev #108)

Date: 2026-09-03
Ticket: Skynet Autodev #108 — "Aucune sonde n'exerce danger-claude : deux pannes
totales du modèle en deux jours, `/healthz` au vert les deux fois"

**The ticket's premise is wrong, and correcting it makes this cheaper.** A probe
does exercise `danger-claude`, once per cycle, and has since Autodev #46. What
it does not do is keep what the probe answered. So this is not "add a probe" —
no new container round-trip to arbitrate, no cadence to choose, no token cost to
weigh. It is "stop discarding the verdict of a call that already happens".

Related, **not** implemented here: Autodev #107 (an infra outage spends the
review budget) and Autodev #103 (a 401 parks a request where no pass looks for
it). Both are consequences of the same two incidents. This ticket makes the
outage *visible* and stops dispatching work into it; #107 stops counting it as a
verdict, and #103 gets the parked rows back.

## Problem

### The probe already exists, and it exercises the whole chain

`UsageGate.probe!` (`app/services/autodev/usage_gate.rb:43`) is called once per
cycle from `AutodevPollJob:32`, before any dispatch pass. It delegates to
`UsageChecker#available?`, whose probe is:

```ruby
# lib/autodev/usage_checker.rb:43
def send_probe
  Open3.capture3(DangerClaudeRunner::CLEAN_ENV,
                 'danger-claude', '-p', 'ok', '--max-turns', '1',
                 stdin_data: '.')
end
```

That call proves the entire chain the ticket asks to prove: the binary is on
PATH, the container runtime answers, the four volumes resolve, the credentials
authenticate, the quota is there. Nothing needs to be added to reach it.

`UsageChecker`'s own `CACHE_TTL` never applies: `UsageGate` instantiates a fresh
checker per cycle, so `@checked_at` is always nil and every cycle probes live.
`UsageGate`'s class comment already says so.

### It keeps one signature and discards every other outcome

```ruby
# lib/autodev/usage_checker.rb:27
def check!
  out, err, status = send_probe
  @checked_at = Time.now
  @available = !rate_limit?(status, "#{out}\n#{err}")
  ...
rescue StandardError => e
  @checked_at = Time.now
  @available = true # assume available on transient errors
end

def rate_limit?(status, output)
  !status.success? && output.match?(RATE_LIMIT_PATTERN)
end
```

`rate_limit?` demands `RateLimitDetector::PATTERN`. Every other failure —
a 401, a Docker API error, a missing binary — fails that match and lands on
`@available = true`. The `rescue` does the same. Four causes go into the probe;
one boolean comes out, and it reads "available" for three of them.

The signature for one of those three **is already written and already used
elsewhere**: `AuthFailureDetector::PATTERN`
(`lib/autodev/auth_failure_detector.rb:12`) matches `api error: 401`, the exact
string the incident produced. Real `danger-claude` calls run it through
`DangerClaudeRunner#check_dc_failures!`. The probe does not.

### Measured: 262 consecutive "available" through a nine-hour total outage

The Docker engine on bobette migrated to API 1.55 while `danger-claude`'s client
called v1.54. Every invocation failed in `ensure_volume` — *before* any
container started — with:

```
request returned 500 Internal Server Error for API route and version
.../v1.54/volumes/danger-claude, check if the server supports the requested API version
```

Production `activity_events`, `kind = 'usage'`, between 2026-09-02 23:35:57 and
2026-09-03 08:24:07: **262 rows, every one of them `available: 1`**. Nine hours
during which `danger-claude` could not start at all, the gate answered
"available" 262 times, and `check_claude_usage` rendered `ok` on every
`/healthz` in the window. The `/healthz` at 08:14, at the heart of the outage,
carried a `warn` — about four failed jobs in the queue, not about this.

### The 401 was masked by another true cause, not misclassified

In the 401 window (02/09 16:10–16:28) the recorded verdict is `available: 0`.
The quota was *also* exhausted, so `RATE_LIMIT_PATTERN` fired and answered
first. The credential failure left no trace of its own.

This matters more than the fall-through: today the two incidents are
**indistinguishable in the data**. One boolean cannot say which of four causes
produced it, so neither an operator nor a later investigation can tell "the
quota will come back on its own" from "someone has to fix the credentials". It
is the strongest argument for recording the cause rather than the verdict.

### The probe is also unbounded

`Open3.capture3` has no timeout. A `danger-claude` that hangs hangs the poll
cycle indefinitely — and a probe that hangs reports nothing, which is the
ticket's own subject. `DangerClaudeRunner:104` already names this call as a
bypass sitting outside the timeout guarantees. Production cycle durations carry
a 9-hour maximum.

### Measured cost of the probe (bobette, 2026-09-03)

Mac mini M1, Docker API 1.55, image present (2.17 GB), four volumes present.

| phase | duration |
|---|---|
| `ensure_volume` — 4 × `docker volume inspect` | 70 ms |
| `docker run --rm danger-claude true` | 170 ms |
| `danger-claude -s "echo hi"` — whole script, container, no model | 375 ms |
| probe on the failing path (quota exhausted) | 1–2 s |

Distribution over 25 h of production, 619 cycles paired by Solid Queue's
scheduled `run_at` against the `usage` event that ends the probe:

* quota-exhausted population — clean, because nothing consumes and no worker
  contends: **p50 2.02 s, p95 2.23 s, p99 2.71 s**;
* successful population — **p50 4.95 s**. Its tail (p90 72 s) is queue wait, not
  probe: when the quota is available the workers are running real
  `danger-claude` calls and the poll job waits behind them. Contention can only
  inflate the figure, never reduce it, so 4.95 s is an upper bound on the true
  median.

For comparison, the same probe on a development Mac 2.5–9× slower at container
start takes 6.7–11.5 s.

So: a probe that succeeds costs 3–5 s on bobette, and every failing path answers
in under 3 s.

## Design

### 1. `UsageChecker` answers a typed verdict, not a boolean

`#available?` is replaced by `#verdict`, returning

```ruby
{ status: <one of the six below>, diagnostic: String|nil }
```

`diagnostic` is set only for `broken`: the combined stdout/stderr, scrubbed
through `Redactor` and truncated, so the health card can name what nobody
enumerated. It is never set for the recognised causes — their name *is* the
diagnosis.

Interface change, with its full blast radius: `UsageGate.probe!` is the only
production caller. Three test files stub `UsageChecker.new` with fakes that
answer `available?` (`test/services/autodev/usage_gate_test.rb`,
`test/jobs/autodev_poll_job_test.rb`, `test/mr_review_token_probe_test.rb`) and
must be updated to answer `verdict`.

The instance-level `CACHE_TTL` cache is left exactly as it is. It is already
dead in practice — a fresh checker per cycle — and reviving or removing it is
not this ticket's business.

### 2. The classification rule: a non-zero exit is an answer

| status | trigger |
|---|---|
| `available` | exit 0 |
| `quota_exhausted` | `RateLimitDetector::PATTERN` — the only case recognised today, unchanged |
| `auth_refused` | `AuthFailureDetector::PATTERN` — already written, already used by real calls |
| `binary_missing` | `Errno::ENOENT` from the spawn |
| `broken` | non-zero exit, no recognised signature; carries the scrubbed diagnostic |
| `unknown` | the probe could not answer at all: timeout, or any other exception |

The load-bearing line is between `broken` and `unknown`. **A non-zero exit is an
answer**: the tool ran and failed. What is unknown is *why*, not *whether*. A
timeout or an exception, by contrast, means the probe never got an answer — and
Autodev #62's rule applies there and only there: a read that did not happen
accuses nobody.

The consequence is what makes this cheap: **the Docker outage is caught without
recognising its signature**. Its 500 exits non-zero with no known pattern, so it
is `broken`, and `broken` is a definite failure. Adding a Docker-specific
pattern would buy a nicer label, not a detection, so it is not written.

Order of evaluation matters and is fixed: `quota_exhausted` before
`auth_refused`, matching today's precedence, so a cycle where both are true
keeps reading as a quota problem — the cause that resolves itself.

### 3. The probe gets a 30-second timeout

Calibrated on the measurements above, not chosen: 30 s is six times the observed
p50 of a successful probe, eleven times the p99 of every failing path, eighty
times the whole-container cost, and a quarter of the production `poll_interval`
of 120 s.

A timeout classifies `unknown`, never `broken`. A tool that has not finished
answering has not answered, so an over-tight value costs one observation and
never a false outage — which is what makes 30 s safe to pick from a median
rather than from a tail nobody can measure cleanly.

A constant with the calibration written in its comment, in the style of
`HealthReport::DEFAULT_REVIEW_FAILURE_WINDOW`. No config key: nothing has asked
for one, and Autodev #58 says that a setting which exists must also be bounded
and validated at boot — cost that buys nothing here.

`ProcessRunner#run_with_timeout` cannot be reused: it depends on `@dc_stdout`,
`@dc_stderr`, `@project_config`, `@config` and `@port_mappings`, none of which a
probe has any business owning, and it spawns with `in: :close` while the probe
must write `'.'` to the child's stdin. `UsageChecker` gets its own small bounded
spawn, reproducing `ProcessRunner`'s kill sequence — TERM to the process group,
then KILL — because a `Timeout.timeout` around `Open3.capture3` leaves the
container running. Extracting a shared bounded-spawn primitive is the obvious
follow-up and is deliberately out of scope.

### 4. `UsageGate` records the cause; `available?` keeps its question

The recorded payload gains `status` and, for `broken`, `diagnostic`, alongside
the `available` boolean it already writes — so a row stays readable by the
current code and by anything reading history.

`UsageGate.state` gains `status` and `diagnostic`. `UsageGate.available?` keeps
answering exactly the question its three consumers ask — "may we spend a
`danger-claude` call?" — and answers false on `quota_exhausted`,
`auth_refused`, `binary_missing` and `broken`; true on `available` and
`unknown`. Its consumers are unchanged:
`app/jobs/issue_process_job.rb:106`, `lib/autodev/pipeline_monitor.rb:156`, and
`PollDispatcher` through `usage_ok` from `AutodevPollJob:32`.

The fail-open doctrine in `UsageGate`'s comment is preserved where it actually
says something: it protects a failure to **observe** the quota, and `unknown`
still fails open. A verdict that the tool is broken is an observation, not the
absence of one.

No hysteresis. A single misclassified cycle costs one skipped cycle — two
minutes, recovered by the next probe — whereas requiring two consecutive
occurrences would cost a cycle of delay on every real outage, and Autodev #99
has just shown what consecutive-occurrence counters are worth when the loop
writes to what they measure.

### 5. Two health cards from one probe

Both read the same `ActivityEvent(kind: 'usage')`. No new probe, no new
round-trip, no new TTL, and `HealthReport` stays passive by contract.

* `claude_usage` keeps exactly its present scope, the quota: `warn` on
  `quota_exhausted`, `ok` otherwise. No behaviour change for the expected case.
* `danger_claude` is new: `down` on `auth_refused`, `binary_missing` and
  `broken`; `ok` on `available`, on `unknown`, and on `quota_exhausted` — an
  exhausted quota is not a fault of the tool. Its `detail` names the cause and
  quotes the truncated diagnostic for `broken`.

`down` puts `/healthz` on 503, which pages. That is the intent: it is the tier
`migrations` already occupies, for the same stated reason — every job fails.
`mr_review` and `mr_review_token` stay `warn` because a broken review does not
stop delivery; a `danger-claude` that cannot run stops implementation, review
and discussion fixing alike.

`CHECKS` gains `danger_claude`, which also makes it addressable as
`/healthz/danger_claude`.

### 6. The dashboard banner must name the cause

`Web::Views::Dashboard#usage_paused?` (`app/components/web/views/dashboard.rb:321`)
renders on `available == false`, with the text *"Quota Claude épuisé"* /
*"Claude quota exhausted"*. Widening the gate without touching this would make a
Docker outage render "quota exhausted" — autodev asserting something its own
state contradicts, which is the family of defect this whole lot exists to end.

So the banner reads the recorded `status` and carries per-cause title and hint.
`quota_exhausted` keeps the current wording verbatim; the three fault causes get
their own, saying that the tool cannot run and that a human has to act.

### 7. The quota deferral must name the cause too

`PipelineMonitor#defer_review_for_usage` and `#defer_fix_for_usage`
(`lib/autodev/pipeline_monitor.rb:206` and `:212`) are reached from
`claude_available?`, so widening `available?` reaches them. Both raise
`poll_inconclusive!(:claude_usage_exhausted)` and log "Claude usage exhausted,
deferring mr-review" — a sentence that a dead Docker engine would produce
verbatim. Same defect as the banner, one layer down, and the reason label is
read back by the age bound's own log line ("this poll could not conclude
(<reason>)").

So both take the recorded cause: the flag's reason and the log line name what
actually happened. Standing the age bound down stays correct for every cause —
"an infrastructure failure or a quota outage must never be the reason a 14-day-old
ticket is given up" (Autodev #56) covers a broken tool as squarely as an
exhausted quota.

Found while specifying Autodev #107, which depends on this gate.

### 8. Where the code goes

* `lib/autodev/usage_checker.rb` — verdict vocabulary, classification, bounded spawn.
* `app/services/autodev/usage_gate.rb` — record and expose the cause; widen `available?`.
* `app/services/autodev/health_report.rb` — `check_danger_claude`, `CHECKS`, and `check_claude_usage` narrowed to the quota.
* `lib/autodev/pipeline_monitor.rb` — the two quota deferrals name the cause.
* `app/components/web/views/dashboard.rb` — per-cause banner.
* `config/locales/web.{fr,en}.yml` — card label and banner strings.

## Testing

TDD, and the regression that matters is written first: **a 401 output must not
answer "available"**, and neither must the Docker 500.

* One test per verdict, injecting the probe's captured output and exit status,
  asserting the triple that follows from it: the gate boolean, the
  `claude_usage` severity, and the `danger_claude` severity.
* Both real incidents as fixtures: the `api error: 401` output of 02/09, and the
  verbatim `v1.54/volumes/danger-claude` 500.
* Precedence: an output carrying both a rate-limit and a 401 signature reads
  `quota_exhausted`.
* `broken` carries a diagnostic; the recognised causes do not.
* The diagnostic is scrubbed — a probe output seeded with a token must not reach
  the recorded payload, the same guarantee Autodev #59 established for
  `dc_stdout`.
* Timeout: a probe that outlives the cap answers `unknown`, the gate stays open,
  and the child's process group is killed rather than left running.
* `Errno::ENOENT` answers `binary_missing`.
* `UsageGate.state` on a row written by the current code — no `status` key —
  still reads, so a verdict recorded before the upgrade is not a crash.
* The dashboard renders the quota wording for `quota_exhausted` and the fault
  wording for `broken`.
* A deferral under `broken` does not say "quota exhausted", and the age bound
  still stands down.

## Docs and i18n

* `web_admin_health_check_danger_claude`, and the per-cause banner titles and
  hints, in **both** `web.fr.yml` and `web.en.yml`, with identical `%{var}`
  placeholders — `CLAUDE.md` §Localization step 2. Autodev #68 is why this is
  called out rather than assumed: a missing key fails no test, so nothing but
  the discipline catches it.
* Health-card `detail` strings stay English, like every other card in
  `HealthReport`.
* `CLAUDE.md:266` (§PollDispatcher + IssueProcessJob) states that the entry
  point "gates on `UsageChecker#available?`". That method is being removed, and
  the sentence is stale in a second way — since Autodev #46 the gate pauses only
  the passes that reach `danger-claude`, not "the polling". It gets the verdict
  vocabulary and the fact that a tool fault now closes the gate.
* `CHANGELOG.md` `[Unreleased]`.

## Constraints

TDD. RuboCop green over the whole tree. Conventional Commits. `CHANGELOG.md`
`[Unreleased]` updated in the same pass. i18n fr **and** en for every visible
string. Branch `fix/108-danger-claude-probe-verdict`.

## Out of scope

* **Recognising the Docker signature specifically.** `broken` already catches
  it; a pattern would add a label, not a detection.
* **A shared bounded-spawn primitive** extracted from `ProcessRunner` and this
  probe. Tempting, and real, but it is refactoring beyond the ticket.
* **The review budget.** That an infra outage spends `review_failure_count` is
  Autodev #107. Closing the gate removes most of the occasions, but not the
  defect: a fault that starts mid-cycle still reaches the reviewer.
* **The parked rows.** Listing the requests an outage left behind is
  Autodev #103. This ticket makes the outage visible; it does not recover what
  it stranded.
* **Reviving or removing `UsageChecker`'s dead instance cache.**
* **The arrears sweep running ungated.** The 401 incident reached
  `danger-claude` through `ReviewArrearsSweep` run by hand with `APPLY=1`, which
  no gate covers. Worth a ticket of its own; not this one.

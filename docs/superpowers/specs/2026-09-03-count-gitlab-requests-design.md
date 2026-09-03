# Counting the GitLab requests autodev makes (Autodev #96, #82, #104)

Autodev #96 is an instruction ticket: understand what makes GitLab
intermittent from production, and what load autodev puts on it. #82 (a
wasted review run on an MR with no `diff_refs` yet) and #104 (host-side and
retry angles on the same intermittency) were merged into it. The instruction
closed three of its four questions without writing a line of product code —
point 4 (the network path) is exonerated, point 1 (request volume) is
answered but **derived from reading the code, not measured**, and point 3
(the hourly correlation) could not be decided by hand-sampling. This spec
scopes the one piece of code the instruction asks for: make the volume and
the failures a matter of record instead of a matter of arithmetic.

## What the instruction already established

**Point 4 — closed.** NetBird is not on the path to `source.modulotech.fr`
(public IP, no AAAA record, same gateway on `en0` from bobette and from a dev
box). A 1-2% background connection-failure rate is present from both
networks and is not reproducible on demand — which is exactly why "reproduce
then fix" was abandoned in favour of instrumenting the thing as it runs.

**The ordinary poll is affected, not just burst tooling.** Two
`IssueProcessJob`s failed overnight on `Net::OpenTimeout` to the same host,
landing in `solid_queue_failed_executions` — a terminal failure needing a
manual replay. The arrears catch-up saw ~9% read failures over four passes,
always `Failed to open TCP connection … (connect(2))`, never an HTTP
response.

**Point 1 — answered, but derived.** At `poll_interval` 120s, two projects,
143 issue rows: the poll itself costs a handful of requests per cycle
(discovery, unassignment sweep), but the dominant cost is in the jobs —
`check_pipeline` pays ~6 requests per watched row per cycle (the MR, pipeline
jobs, target-branch resolution, unresolved discussions, the activity note).
**~30-45 requests per 2-minute cycle, ~900-1300/hour**, and the shape is
O(active rows) + O(stagnating rows) for the poll, O(active rows) × 6 for the
jobs — at 25 active rows (one arrears pass can produce that many) the same
code produces 150-180 requests/cycle with nothing having changed. None of
this is measured; it is read off `GitlabHelpers`, `PipelineMonitor` and the
dispatcher passes.

**Point 3 — indecidable by hand.** Four manual samples are not a curve. A
bounded transport probe ran 03/09 11:15 UTC → 04/09 ~11:15 UTC on bobette (96
samples, one per 15 minutes, `/tmp/gl-probe.csv`) and stops on its own. It is
not renewed, not replaced by a cron, and it answers nothing past its own 24h
window — which is the gap this ticket's implementation closes going forward.

**Point 2 — blocked, out of scope, and staying that way.** Autodev's share of
the *instance's* traffic needs GitLab-side data (Prometheus metrics or access
logs) nobody here has access to. Point 1 gives the numerator only; nothing in
this repository, however instrumented, can produce the denominator. This is
not deferred pending more code — no code on autodev's side can answer it.
It is named explicitly so a future reader does not reopen it expecting a
different answer from more instrumentation.

**The instruction's own recommendation, and this spec's scope.** Nothing
today counts a single GitLab request; point 1's whole answer is arithmetic
on the code. It is fixable close to free because the client is built in
exactly one place — confirmed below — so wrapping what `GitlabHelpers`
returns instruments every call, reads and writes, without a single call site
changing. Writes matter here specifically because `GitlabHelpers.answer`,
the funnel the *read* estimate above is built from, is a read-only funnel —
`create_merge_request_discussion`, `resolve_merge_request_discussion`,
`upload_file` and the rest never pass through it, so a counter placed there
instead would silently answer point 1 for half the traffic. Alongside the
counter, every transport failure needs to be recorded with a
millisecond-precision timestamp and enough context to place it, so point 3
gets an actual rate and an actual hourly shape instead of one 24h manual
sample, permanently, without hand-sampling again.

## Confirming the premise before building on it

The recommendation depends on "the client is built in exactly one place."
Checked directly rather than assumed:

```
$ grep -rn 'Gitlab\.client\b' app lib
lib/autodev/gitlab_helpers.rb:99:    Gitlab.client(endpoint: "#{gitlab_url}/api/v4", private_token: token)
```

One call, inside `GitlabHelpers.build_gitlab_client`. Twelve call sites hand
it a `gitlab_url`/token pair and get a client back (`IssueProcessJob`,
`DeployReviewsController`, `Autodev::ClarificationSweep`,
`Autodev::GitlabMembershipSync`, `Autodev::MrReviewTokenProbe`,
`Autodev::PollDispatcher`, `Autodev::ReviewSkillProbe`,
`Autodev::ReviewArrearsSweep`, `Autodev::DeployReview`,
`Autospec::GitlabImporter`, `Autospec::GitlabSubmitter`, `PollRouter`) — none
of them touch `Gitlab.client` directly. The premise holds: wrapping the
return value of `build_gitlab_client` reaches every caller.

## Design

### 1. A counting proxy around the client `GitlabHelpers` returns

`GitlabRequestCounter` (`lib/autodev/gitlab_request_counter.rb`, a plain
top-level class alongside `GitlabHelpers`/`GitlabFailure` — `lib/` is off the
Zeitwerk autoload path by design, and this sits next to the file it wraps)
is a `SimpleDelegator` around the `Gitlab::Client` instance. It overrides
`method_missing`/`respond_to_missing?` so every call the wrapped client
would have answered records first, then delegates:

```ruby
def method_missing(name, *args, **kwargs, &block)
  target = __getobj__
  return super unless target.respond_to?(name)

  kind = self.class.classify(name)
  GitlabRequestStat.record!(kind: kind, endpoint: name.to_s)
  begin
    target.public_send(name, *args, **kwargs, &block)
  rescue *GitlabHelpers::TRANSPORT_ERRORS => e
    GitlabTransportFailure.record!(kind: kind, endpoint: name.to_s, error: e,
                                    caller_location: caller_locations(1, 1)&.first&.to_s)
    raise
  end
end
```

`build_gitlab_client` wraps its own return value:

```ruby
def build_gitlab_client(gitlab_url, token)
  ...
  GitlabRequestCounter.new(Gitlab.client(endpoint: "#{gitlab_url}/api/v4", private_token: token))
end
```

Every one of the twelve call sites is unchanged — they receive an object
that answers exactly like the raw client (same public interface, forwarded
transparently) and cannot tell the difference except that GitLab's own
answer now has a counted twin.

**Read vs write is a short, explicit classification, not a REST-style
prefix guess.** The gem's own naming is not uniform enough for a prefix rule
alone — `job_play` and `job_retry` are writes with no common prefix with
`create_`/`edit_`/`resolve_`. So: a set of write-shaped prefixes
(`create_`, `edit_`, `update_`, `delete_`, `remove_`, `resolve_`, `upload_`,
`retry_`) covers the regular cases, plus two named exceptions
(`job_play`, `job_retry`) for the irregular ones. Checked against every
distinct `client.*` method this codebase actually calls today (32 of them,
grepped, not guessed) — the twelve writes
(`create_issue`, `create_issue_note`, `create_merge_request`,
`create_merge_request_discussion`, `create_merge_request_note`,
`edit_issue`, `edit_issue_note`, `job_play`, `job_retry`,
`resolve_merge_request_discussion`, `retry_pipeline`, `upload_file`) are all
classified `:write`; the rest (`issue`, `issues`, `issue_notes`,
`merge_request`, `merge_request_discussions`, `pipeline_jobs`, `project`,
`user`, …) fall through to `:read` by default. A method this repository
starts calling tomorrow defaults to `:read` unless it matches a write
prefix or is added to the short exception list — erring towards
undercounting writes rather than inventing a rule broad enough to
misclassify a read.

**Why a proxy and not a counter inside `GitlabHelpers.answer`.** `answer` is
where a failed *read* stops being data (Autodev #62) — every caller that
wraps a read in it already opts in. It is not where writes go: eleven of
the twelve write methods above are called directly, uninstrumented by
`answer`, because a write's failure is not "this unit of work has no
answer" in the same sense — it is "did this land". Counting inside `answer`
would silently miss every write the instruction's own numerator needs
(discussions resolved, notes posted, MRs created), which is exactly the gap
named in the instruction. Wrapping the client counts both without asking
any of the eleven write call sites to opt in.

**Why not a call-site change.** Twelve places already have to agree on
nothing more than "call `build_gitlab_client`". Asking each of them to also
report what they called would be thirteen places to keep in sync (twelve
call sites plus the classification rule itself) instead of one.

### 2. Persisting counts — cheap, and not a row per call

`GitlabRequestStat` (`app/models/gitlab_request_stat.rb`, `ApplicationRecord`
— the primary SQLite DB, the same one `Issue`/`ActivityEvent`/`Project`
live in) is an hourly counter, not a log: one row per
`(hour_bucket, kind, endpoint)` triple, incremented with a SQLite
`ON CONFLICT … DO UPDATE SET count = count + 1` upsert
(`ActiveRecord#upsert_all` with `on_duplicate: Arel.sql(...)`). At the
instruction's own estimate (900-1300 calls/hour across ~20 distinct
endpoints × 2 kinds), this is at most a few dozen rows written or bumped per
hour, not one row per call — the volume point 1 needs is a `SUM(count)`
over a time window, not a table scan over individual requests.

```
create_table :gitlab_request_stats do |t|
  t.datetime :hour_bucket, null: false
  t.string   :kind,        null: false   # 'read' | 'write'
  t.string   :endpoint,    null: false   # gem method name, e.g. 'merge_request'
  t.integer  :count,       null: false, default: 0
  t.timestamps
end
add_index :gitlab_request_stats, %i[hour_bucket kind endpoint], unique: true
```

This is what makes point 1 checkable instead of derived: the ~30-45
requests/cycle estimate, and its O(active rows) × 6 shape, can now be read
back against `GitlabRequestStat` and confirmed or corrected on the real
fleet size instead of on eight traced passes.

### 3. Persisting failures — one row per failure, with millisecond precision

`GitlabTransportFailure` (`app/models/gitlab_transport_failure.rb`) is a row
per transport failure — `answer`'s or `method_missing`'s own
`GitlabHelpers::TRANSPORT_ERRORS` list, the one the codebase already treats
as one family for outages (Autodev #62's third round). At the observed 1-2%
failure rate this is tens of rows a day, not thousands — a log, not a
counter, is the right shape here, and it is the piece point 3 was missing:
a timestamp with millisecond precision is what turns four hand-timed
observations into an hourly curve, and it does not stop accumulating after
one probe's 24h window the way `/tmp/gl-probe.csv` does.

```
create_table :gitlab_transport_failures do |t|
  t.datetime :occurred_at,   null: false, precision: 3
  t.string   :kind,          null: false   # 'read' | 'write'
  t.string   :endpoint,      null: false
  t.string   :error_class,   null: false
  t.string   :error_message
  t.string   :caller_location            # "lib/autodev/pipeline_monitor/api_helpers.rb:42"
  t.timestamps
end
add_index :gitlab_transport_failures, :occurred_at
```

**Context, without touching a call site.** The proxy has no cooperation
from its caller — no issue id, no project path is passed in. What it does
have for free is `caller_locations`, which pinpoints exactly which line in
the codebase issued the request that failed (`file:line`), and costs
nothing to capture. Call arguments are deliberately not dumped: several
callers pass free-text (issue bodies, comment text) as positional
arguments, and a failure log is not the place to decide, request by
request, whether that text is safe to persist. `caller_location` plus
`endpoint` plus `kind` is enough to place a failure in the codebase and in
time; identifying *which issue* it was serving, if ever needed, is a
question for the surrounding job's own logging, not this table's job to
answer.

Both models fail closed the same way `UsageGate`/`ReviewSkillProbe` do:
`record!` rescues `StandardError` and returns `nil` rather than propagate —
instrumentation must never be what turns a successful GitLab call, or the
handling of a failed one, into a second failure.

### 4. Exposing the numbers: `/healthz` and `/admin/health`, for free

`Autodev::HealthReport` is explicitly documented as passive — "it never
shells out to danger-claude or calls GitLab, so it's instant and safe to
hammer from an external probe." Reading `GitlabRequestStat` and
`GitlabTransportFailure` back does not call GitLab; it reads what the last
however-many calls already recorded, the same shape as `UsageGate` and
`ReviewSkillProbe`'s "the poll cycle probes, everyone else reads the
verdict" — except here there is no separate probe step, because every real
GitLab call *is* the probe.

A new check, `:gitlab_requests`, appended to `HealthReport::CHECKS`:

```ruby
def check_gitlab_requests
  by_kind = GitlabRequestStat.by_kind_since(@now - 3600)
  failures = GitlabTransportFailure.count_since(@now - 86_400)
  total_day = GitlabRequestStat.total_since(@now - 86_400)
  rate = total_day.positive? ? (failures.to_f / total_day * 100).round(2) : 0.0
  meta = { reads_last_hour: by_kind['read'].to_i, writes_last_hour: by_kind['write'].to_i,
           total_last_hour: by_kind.values.sum, failures_last_24h: failures,
           requests_last_24h: total_day, failure_rate_pct: rate }
  build(:ok, "#{by_kind.values.sum} GitLab request(s) in the last hour, #{failures} transport " \
             "failure(s) in the last 24h (#{rate}%)", meta)
end
```

Always `:ok` — this check has nothing to alert on yet. No failure-rate
threshold exists to warn against: producing one is what this instrumentation
is *for*, not something to guess at before the first real numbers exist.
Once a baseline is on file, turning part of this into an alerting tier is a
one-line change in a later ticket, informed by data instead of by another
guess.

`HealthController`/`Web::Views::Admin::Health` render every entry in
`report[:checks]` generically (one card per check, keyed off
`t_web(:"web_admin_health_check_#{name}")`) — adding the check to `CHECKS`
and its two locale keys is what puts it on `/admin/health` and
`/healthz(.json)` simultaneously, with no view code to write. This answers
"sonde de santé, tableau de bord, ou les deux" with both, at the cost of one
check method.

## What this does not do, and why

**Point 2 (autodev's share of instance traffic) is not attempted.** Argued
above: no code on this side of the wire produces the denominator. Recording
it as "blocked, needs GitLab-side access" is the honest state, not a TODO.

**No load-reduction change ships here.** Intra-cycle caching, spacing out
passes, cheaper reviews, backoff with jitter — none of it is touched. The
instruction measured a volume and a shape, not a cause; nothing measured
so far designates any of these as *the* fix for an intermittency that is
not reproducible on demand and might be entirely on GitLab's side. Shipping
a load reduction now would be optimizing against a guess the very
instrumentation in this spec exists to replace with a number. Once
`GitlabRequestStat`/`GitlabTransportFailure` have run for a few days, a
follow-up ticket can point at whichever of these actually correlates with
the failure rate — or at none of them, if the fault turns out to be
entirely GitLab-side, which point 4's host-side angle below leaves open.

**The #82 design question is not decided here.** Where the rule "an MR
without `diff_refs` is not publishable" should live — today only
`ReviewPublisher` discovers it, after a full clone, skill injection and
review pass have already run under `mr_review_timeout` — is unresolved. The
reviewer's proposal (read `diff_refs` before the review starts) was
rejected once already because it moves the rule out of the one class that
owns it. Autodev #95 puts a number on the cost of leaving it as is (a
five-cycle repeat, ~90 minutes of model time, until `InvalidRequestBound`
stopped it) but that number does not decide the design question, and this
ticket's scope is instrumentation, not the review pipeline. Left for its
own ticket, with the #95 figure and the rejected proposal both on record so
it is not re-litigated from zero.

**The #104 host-side and retry ideas are not implemented.** "Look at socket
exhaustion / file-descriptor limits / the TLS layer on the host" and "retry
once inside a re-arm instead of spending the slot" are both plausible and
both untested against real data. The retry idea in particular interacts
directly with what this spec ships — a retried call is a second recorded
attempt, and `GitlabTransportFailure`'s hourly curve is exactly what would
tell a future ticket whether one extra retry would have absorbed most of
the observed failures, or hardly any. Implementing the retry before that
curve exists would be shipping the answer to a question this ticket has
not yet asked GitLab. Both ideas are left for a follow-up that can read the
data this spec starts collecting.

**No retention/pruning job.** At the estimated volume (a few dozen
`GitlabRequestStat` rows bumped per hour, tens of `GitlabTransportFailure`
rows a day) neither table is a growth concern over the "several days" this
instruction asks for. If this instrumentation is still running months from
now, a janitor in the shape of `Autodev::ActivityEventJanitor` is the
obvious follow-up — not written here because no retention window can be
picked correctly before the data says how long it needs to be kept to stay
useful.

## Testing

- `GitlabRequestCounter.classify` returns `:write` for every write-shaped
  method this codebase calls today, and `:read` for everything else,
  including a method not in either list.
- Calling a delegated method through the proxy increments the matching
  `GitlabRequestStat` row (creates it on the first call, bumps `count` on
  the next).
- A method the wrapped client does not respond to still raises
  `NoMethodError`, uninstrumented.
- A call that raises one of `GitlabHelpers::TRANSPORT_ERRORS` still
  raises it to the caller, unchanged, after recording a
  `GitlabTransportFailure` row with the endpoint, the kind and the error
  class.
- A call that raises anything **not** in `TRANSPORT_ERRORS` (e.g. a
  programming error) is not recorded as a transport failure and is not
  swallowed.
- `GitlabRequestStat.record!`/`GitlabTransportFailure.record!` never raise
  — a broken DB write must not turn a successful GitLab call into a
  failure, or a real transport failure into two.
- `GitlabHelpers.build_gitlab_client` returns a `GitlabRequestCounter`
  wrapping the real client, not the raw client itself.
- `HealthReport#check(:gitlab_requests)` reports the right totals from
  seeded `GitlabRequestStat`/`GitlabTransportFailure` rows, computes the
  failure rate correctly (including the zero-requests case, which must
  not divide by zero), and is always `:ok`.
- The existing `HealthReport` "worst severity" test's expected `CHECKS`
  list gains `:gitlab_requests` at the end.

Every test file must pass run on its own (Autodev #64). Any user-facing
string (the two new locale keys) goes through `Locales.t`/`t_web` in `fr`
and `en`.

## Constraints

TDD, RuboCop green (`mise x ruby -- rubocop`, no `.rubocop.yml` edits),
`CHANGELOG.md` `[Unreleased]` updated in the same pass as the code (not
this spec commit — spec-only commits skip the changelog by repository
convention), Conventional Commits, i18n `fr`/`en` for the two new
`web_admin_health_check_gitlab_requests` keys.

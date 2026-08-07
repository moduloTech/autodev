# Dormant-rows audit (Autodev #47 + #48)

Date: 2026-08-07
Tickets:
- Skynet Autodev #47 — "Une demande `pending` orpheline n'est rattrapée par aucune passe de poll"
- Skynet Autodev #48 — "`dispatch_unassignment` ignore les lignes `pending` et `error` : clôtures et désassignations jamais vues"

## Problem

Both tickets were found on 2026-08-06 while validating the `1.0.0-alpha.45`
deploy: 14 `pending` rows frozen on `powerpanne/core`, the oldest since April
13th. They are two halves of one gap, so they get one design.

### #47 — a `pending` row can become invisible to every pass

A `pending` row is rediscovered by exactly two paths, and each has a condition
those rows did not meet:

- `dispatch_new_issues` queries GitLab on `labels_todo`. A request already
  picked up carries `label_doing`, so it is absent from the result set.
- `dispatch_retries` / `fetch_retryable` requires a non-NULL `next_retry_at`.
  The 14 rows had it NULL with `retry_count = 0`.

Invisible to both, indefinitely. 13 of the 14 were still open and still assigned
to autodev: real, requested work, never done, with no signal to the requester.
`HealthReport`'s stuck-issues card did flag them (that is what it is for, #25),
but nothing acts on it and nobody was reading it.

This is the pattern #26 then #34 fixed on the *reset* paths —
`Issue.reset_for_retry!` now stamps `next_retry_at` on the pre-MR branch — but
nothing catches rows that fell in before that fix, or that fall in by another
route.

`FailedJobReaper` reveals one such route still open. It discards a pruned
worker's in-flight jobs with the comment "no work is lost: a pruned
`check_pipeline` issue is re-dispatched on the next poll". True for
`checking_pipeline`; false for `cloning` / `implementing` / … — no pass
re-dispatches those. A pruned worker mid-implementation leaves an orphan active
row until the service restarts and `Issue.recover_on_startup!` runs.

### #48 — closures and unassignments are never seen on dormant rows

`PollDispatcher#dispatch_unassignment` only sweeps `ACTIVE_STATUSES`. Neither
`pending` nor `error` is in it. That was a deliberate scope call in #44 ("a
ticket closed while parked in `pending`/`error` is noticed whenever it next
moves"), resting on an assumption: a row always eventually moves. The assumption
is false. A `pending` row with no `next_retry_at`, or an `error` row with a spent
budget and a consumed recheck cap, never moves again.

Two real cases in the 2026-08-06 batch, both left in a false state:

- `#16207` — closed on GitLab, still `pending` locally. If it ever restarts,
  autodev works on an abandoned ticket and burns Claude quota for nothing.
- `#15909` — unassigned from autodev (label moved to `Development::Awaiting CR`,
  a human took over), still `pending`. If it restarts, autodev resumes work that
  is no longer its own and may overwrite what that person did.

Both also skew the dashboard counters: they count as "waiting" when they are no
longer work to do.

The risk is not theoretical and it grows with #47: once automatic re-arming of
`pending` rows exists, those rows restart for real — which is precisely when the
closure and the unassignment must already have been seen.

### Why one design

`dispatch_error_recheck#worth_rearming?` (#34) and
`dispatch_unassignment#check_external_state` (#44) ask the GitLab API the *exact
same question* — `state` + `assignees` — and only differ in what they conclude
from the answer. Shipping #47 and #48 as separate passes would mean asking that
question twice per row per cycle, and would make "closure seen before re-arm" a
matter of pass ordering rather than of control flow.

## Design

### 1. `dispatch_dormant_audit` — one pass, three populations, three outcomes

A single new pass **replaces** `dispatch_error_recheck`. `#34` becomes one arm of
it rather than its twin.

**Selection — three arms, one query each:**

| Arm | Predicate | Why it is dormant |
|---|---|---|
| `pending` | `next_retry_at IS NULL` + no activity within the poller staleness window | Invisible to `dispatch_new_issues` (carries `label_doing`) *and* to `dispatch_retries` (needs a stamp) — the #47 bug |
| `error` | `retry_count > max_retries` + backoff elapsed | Spent budget — #34's current population, unchanged |
| active | `HealthReport::ACTIVE_STUCK_STATES` + no activity for 2h | Worker pruned in flight: `FailedJobReaper` discards the job, no pass re-dispatches |

All three share the same bound: `dormant_recheck_count < cap` and
`dormant_recheck_at` NULL or elapsed.

Windows are the ones `HealthReport` already defines, not new knobs:
`poll_stale_after` = `max(poll_interval × poll_stale_factor, 900s)` for the
`pending` arm, `stuck_active_after` (`STUCK_ACTIVE_AFTER = 7200`, overridable via
`monitoring.stuck_active_after_seconds`) for the active arm.

The age threshold on the `pending` arm is load-bearing: `find_or_create_issue`
creates a row with `next_retry_at` NULL and then enqueues
`IssueProcessJob(:process)`. Without the threshold the pass would audit every
freshly discovered ticket in the gap between those two statements.

**Routing — one GitLab read, three outcomes:**

```
audit_dormant(issue)
  bump dormant_recheck_count            # bounded cost, consumed even when declined
  gl = @client.issue(@path, issue.issue_iid)
  ├─ state == 'closed'       → close_externally(issue)
  ├─ not assigned to autodev → stop_unassigned(issue)
  └─ open + assigned         → revive(issue)
       ├─ pending / error    → retry_count: 0, next_retry_at: Time.current
       └─ frozen active      → Issue.revive_stalled!(scope)
```

`close_externally` and `stop_unassigned` already exist and are already exercised
by `dispatch_unassignment`; the AASM `close` event already accepts `pending` and
`error` as source states, so no state-machine change is needed.

Two properties fall out of this shape:

1. **Closure is seen before re-arming.** The risk #48 flags is not solved by
   ordering two passes — it is the `return` of an `if`.
2. **No retry mechanics are reimplemented.** Like #34, the pass repositions state
   and lets `dispatch_retries` — which runs immediately after — do the work,
   labels and activity log included.

**Placement in `dispatch_existing`:** exactly where `dispatch_error_recheck` sits
today, i.e. just before `dispatch_retries`, so a budget re-armed this cycle is
picked up in the same cycle.

**Accepted redundancy.** `dispatch_unassignment` already reads GitLab every cycle
for active states, so the active arm re-reads what the previous pass just read.
This is accepted rather than optimised away: one code path for all three arms is
worth more than an optimisation resting on "if the row is still active, the
previous pass validated that it is ours". The overhead is bounded by the backoff
and only concerns frozen rows, which are rare.

**Claude quota.** The pass never shells out to danger-claude — GitLab reads and
DB transitions only — so it runs during a quota outage like the other
observation passes (#46). The guard already exists downstream: a re-armed
`pending` row dispatches as `:retry_stuck`, which `enqueue_retry` defers when
Claude is unavailable; the row keeps its stamp and is retried next cycle. No new
code.

**Scope not taken.** `dispatch_unassignment` keeps its current perimeter (active
states, every cycle). Extending its `WHERE` to `pending` / `error` would be the
literal reading of #48, but it means querying GitLab every cycle for rows that by
definition do not move. This pass covers both populations behind a backoff — same
fix, right price. See "Bounded cost" below.

### 2. Migration: `error_recheck_*` → `dormant_recheck_*`

```ruby
# db/migrate/20260807000001_rename_error_recheck_to_dormant_recheck.rb
rename_column :issues, :error_recheck_count, :dormant_recheck_count
rename_column :issues, :error_recheck_at,    :dormant_recheck_at
```

The columns change name, not meaning: they already carried "how many bounded
second chances this row has been granted"; only the population widens.
Reversible, lossless — an `error` row mid-cap keeps its counter and its date.

Config keys follow — `dormant_audit_max` / `dormant_audit_backoff`, same defaults
(3 rounds, 3600s) — with a read-through fallback on the legacy
`error_recheck_max` / `error_recheck_backoff` names so an already-tuned
production `~/.autodev/config.yml` keeps working. Resolution order per key stays
project config → global config → default.

### 3. `Issue.without_activity_since` — one definition of "stuck"

This is the part that stops the regression from coming back. `HealthReport` and
the pass must read the same thing, or the card flags what the pass does not
catch — the exact gap that produced #47.

```ruby
# app/models/issue.rb
# No activity_events row since `cutoff`, falling back to issues.created_at when
# the row has never emitted anything. The lookup is bounded by the candidate
# rows' ids — never by the time window alone, and never over the whole
# activity_events table. No index on that table leads with `created_at`, so an
# unbounded form degrades to a full scan (measured at 0.79s against ~1ms on an
# 800k-row DB) on an endpoint /healthz may poll constantly.
scope :without_activity_since, ->(cutoff) { <candidate rows whose latest activity_events.created_at, or created_at when none, is older than cutoff> }
```

`HealthReport#stuck_issues` is rewritten on top of this scope. It keeps its two
windows (poller for `pending`, 2h for active states) — those are its parameters,
not its logic.

### 4. `Issue.revive_stalled!(scope)` — one rule for unsticking a row

`recover_on_startup!` already knows how to restart each active state, and the
rules are not uniform:

| State | Rule | Source |
|---|---|---|
| `cloning` … `creating_mr` | `reset_for_retry!` → pre-MR `pending` + stamp, post-MR `checking_pipeline` | `recover_stuck_processing!` |
| `reviewing`, `fixing_pipeline` | → `checking_pipeline` | `recover_reviewing!` / `recover_fixing_pipeline!` |
| `running_post_completion` | → `done`, not replayed (the hook is non-fatal) | `recover_post_completion!` |
| `fixing_discussions` | → `checking_pipeline` | **new** — carries an MR; `PipelineMonitor` re-derives whether discussions remain |
| `answering_question` | → `pending` + stamp | **new** — pre-MR, same shape as `recover_stuck_processing!` |

Extract that family into `Issue.revive_stalled!(scope)`; `recover_on_startup!`
calls it, and so does the pass's active arm. Without the extraction the arm would
re-derive these rules, and `running_post_completion` — which carries an MR —
would restart as `checking_pipeline` and redo a review round instead of finishing
as `done`. This is the third time the project meets this pattern; see
`reset_for_retry!`'s own comment ("three call sites used to re-derive this rule
and disagreed").

The last two rows are new: `HealthReport::ACTIVE_STUCK_STATES` monitors
`fixing_discussions` and `answering_question`, but `recover_on_startup!` has no
rule for either — a frozen row in one of those states survives a restart today.
Defining them here closes that gap for both call sites at once, which is the
point of having one definition.

`recover_on_startup!` keeps `recover_errored!` in its composition: that one is
budget-driven, not activity-driven, and belongs to boot recovery only.

### 5. End of cap: `dormant_exhausted`

Today `dispatch_error_recheck` is silent when its cap runs out: the ticket goes
permanently immobile with no signal. That is #47's own complaint, so the unified
pass must not inherit it.

The moment to signal is *not* a refused attempt. Every routing outcome in §1
resolves the row: it ends `closed`, ends `done`, or gets a path forward. A row
dies quietly the other way round — it is revived, falls dormant again, and after
`cap` rounds it simply stops being selected, with nobody told.

So the condition is **at cap and still dormant**, evaluated over the same three
arms with the cap bound inverted. Such a row gets the `needs_attention` trio
stamped once (`attention_reason: 'dormant_exhausted'`, `attention_detail` naming
the cap) plus an activity event, and then appears on `/errors`, in the
`/admin/health` card and on the dashboard with an explicit reason. The mechanism
already exists (`stagnation_pipeline` uses it), and past the cap the row is not a
candidate, so this costs no GitLab call at all.

New i18n keys, in both `fr` and `en`:

- `web_errors_explain_attention_dormant_exhausted` (`config/locales/web.*.yml`)
- `activity_dormant_exhausted` (`config/locales/activity.*.yml`)

Nothing is posted to GitLab: the signal targets the operator, not the requester.
A row exhausts its cap mainly by falling dormant again in a loop, and a comment
in that case can land on a ticket a human is already handling.

### 6. Error handling and bounded cost

`Gitlab::Error::ResponseError` on the read: log and move to the next candidate,
exactly as `recheck_errored` and `check_external_state` do today. The counter is
incremented *before* the read, so an unreachable GitLab project burns the cap
rather than looping forever. Deliberate, and it is #34's current behaviour.

A dormant row costs `cap` GitLab reads in total (3 by default), spaced an hour
apart, then nothing ever again. On the 2026-08-06 batch: 14 rows = 42 calls
spread over 3h, then silence. Compare with extending `dispatch_unassignment`: 14
calls *per 5-minute cycle*, indefinitely.

### 7. Retroactive handling

The 12 recoverable rows were already restarted by hand on 2026-08-06. `#16207`
(closed) and `#15909` (unassigned) remain `pending` with `next_retry_at` NULL and
no activity for months — they land squarely in the `pending` arm. They are left
to the first cycle after deploy rather than fixed by hand: one row per routing
outcome, so they double as the acceptance test. If they do not become `closed`
and `done` on the first pass, the fix is wrong and we know immediately.

## Testing

Written test-first.

**Selection** (`test/services/autodev/poll_dispatcher_test.rb`) — for each of the
three arms: an eligible row is picked up; a freshly created row is not (the
`find_or_create_issue` race); a row at cap is no longer a candidate; a row whose
backoff has not elapsed is not either.

**Routing** — the three outcomes on a `pending` row and on an `error` row:
closed → `closed` + `finished_at` + attention trio cleared; unassigned → `done`;
still ours → `retry_count` 0 + due `next_retry_at`, and `dispatch_retries`
enqueues it in the same cycle.

**Active arm** — a frozen `running_post_completion` row ends as `done`, *not*
`checking_pipeline`. This is the test that protects the `revive_stalled!`
extraction. One case per state in the table, including the two new rules
(`fixing_discussions`, `answering_question`), asserted through both call sites so
`recover_on_startup!` and the pass cannot drift apart.

**Bounds** — the counter is consumed whatever the outcome, including an
unreachable GitLab; a row at the cap that is still dormant is stamped
`dormant_exhausted` exactly once and costs no GitLab read; a row that was
revived, closed or unassigned never enters that set.

**#34 non-regression** — the existing `dispatch_error_recheck` tests are ported
as-is onto the new pass. Identical behaviour on the `error` population; only
names change.

**Config compatibility** — `error_recheck_max` / `error_recheck_backoff` in a
config file still drive the new pass.

**Consistency** (`test/services/health_report_test.rb`) — `HealthReport#stuck_issues`
and the pass's selection see the same set over a given fixture. This is #47's
invariant: what the card flags, the pass catches.

**Model** (`test/models/issue_test.rb`) — `without_activity_since` (including the
`created_at` fallback for rows with no events) and `revive_stalled!` per state.

## Constraints

TDD, RuboCop green (`mise x ruby -- rubocop`), `CHANGELOG.md` `[Unreleased]`
updated in the same pass, Conventional Commits. The changelog entry covers both
tickets, the unified pass, and the config rename with its backward compatibility.

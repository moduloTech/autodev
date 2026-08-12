# Bounding a pipeline watch in time, and stopping the per-poll event (Autodev #53)

Date: 2026-08-11
Ticket: Skynet Autodev #53 — "Borner la surveillance de pipeline dans le temps
(filet de sécurité) et arrêter de journaliser un événement par poll"

## Problem

Nothing bounds a pipeline watch in time. A row in `checking_pipeline` is
re-dispatched by `PollDispatcher#dispatch_pipelines` on **every** cycle, with no
condition other than `status = 'checking_pipeline' AND mr_iid IS NOT NULL`. Every
branch of `PipelineMonitor#dispatch_status` that does not transition —
`RUNNING_STATUSES`, the `else` that catches `manual` / `canceled` / `skipped`,
`handle_no_failed_jobs`, `infra_skip?` below threshold, both Claude-quota
deferrals — leaves the row exactly where it was. The next cycle repeats.

The existing bound is not one. Stagnation detection is fed **only** from
`handle_red`: `infra_skip?` and `check_stagnation_and_fix` are the sole callers
of `update_stagnation_signature(issue, :pipeline, …)`, and both sit under
`when 'failed'`. A pipeline that is never `failed` — a `manual` gate nobody
plays, a `canceled` run, a `skipped` one, or an MR whose head pipeline stays
`created` — never accumulates a signature, so `bail_on_stagnation?` is never
reachable for it. `CLAUDE.md` states this outright as a design decision ("No
blocked state: canceled pipelines keep the issue in `checking_pipeline`
indefinitely until manual intervention"). Indefinitely is the bug.

Two of the known causes are being fixed in parallel (#51 `manual` status, #52
labels/assignment re-read). This ticket is the safety net for the causes we have
not identified yet: whatever the reason a row stops moving, it must stop being
watched eventually.

### The measured cost, production, 2026-08-10

| Fact | Value |
|---|---|
| `activity_events` rows | 898 424 |
| of which `pipeline_checking` | 477 827 (53 %) |
| `~/.autodev/autodev.db` | 264 MB |
| issue #15894 alone | 29 807 events, 29 773 of them polls (99.9 %) |

Every poll of every watched row writes one `activity_events` INSERT.
`PipelineMonitor#check` calls `log_pipeline_poll` unconditionally, before the
GitLab read, and `log_pipeline_poll` calls `log_activity(:pipeline_checking, …,
replace_pattern: POLL_LINE_PATTERN)`. The `replace_pattern` argument makes
`ActivityLogger.upsert` **replace** the corresponding line in the GitLab note —
so the note stays one line — but `persist_event!` runs before that and always
`ActivityEvent.create`s a new row. The note is compacted; the table is not.

The consequences are not only disk:

- `/issues/15894` loads the 200 most recent events, all of which are polls: the
  request's real history is unreachable through the UI.
- the GitLab activity log of that ticket is unreadable for the same reason.
- the dashboard sparkline (`Web::Helpers#weekly_activity_counts`) counts these
  rows, so "Activité de la semaine" measures polling chatter, not work done.
- `/stream` gets one Turbo frame per poll per watched row
  (`ActivityEvent#after_create_commit` → `Web::EventBus`).

## The constraint that governs the logging change

Autodev #50 built an invariant on this table
(`docs/superpowers/specs/2026-08-10-live-worker-silence-invariant-design.md`):

> `Issue.without_activity_since(cutoff)` counts **every** `activity_events` row
> for the issue, heartbeats included, and is the single definition of "this row
> has stopped moving" shared by `DormantAudit`'s active arm and
> `HealthReport`'s "Issues bloquées" card.

`DormantAudit#active_arm` mutates by `update_all`, inline in the poll cycle,
**outside** the `limits_concurrency to: 1, key: "issue-<path>-<iid>"` that
serialises `IssueProcessJob`. Making a row look silent when it is not is
therefore not a reporting bug: it lets the audit reposition a row a live worker
holds.

So before touching the logging, the question is precise: **which readers of
`activity_events` see a `checking_pipeline` row, and what happens to them if the
per-poll row disappears?**

### The answer: no reader looks at `checking_pipeline` — today

| Reader | Population | Contains `checking_pipeline`? |
|---|---|---|
| `DormantAudit#pending_arm` | `status = 'pending'`, `next_retry_at IS NULL` | no |
| `DormantAudit#error_arm` | `status = 'error'`, spent budget (no activity predicate at all) | no |
| `DormantAudit#active_arm` | `Issue::STALLED_STATES` | **no** |
| `HealthReport#stuck_issues`, pending half | `PENDING_STUCK_STATES` = `['pending']` | no |
| `HealthReport#stuck_issues`, active half | `ACTIVE_STUCK_STATES` = `Issue::STALLED_STATES` | **no** |

`Issue::STALLED_STATES` is `REVIVE_TO_PENDING` (`cloning`, `checking_spec`,
`implementing`, `committing`, `pushing`, `creating_mr`, `answering_question`) +
`REVIVE_TO_PIPELINE` (`reviewing`, `fixing_pipeline`, `fixing_discussions`) +
`REVIVE_TO_DONE` (`running_post_completion`). `checking_pipeline` is in none of
the three, by construction: it is the state rows are revived **into**, so
reviving it would be a no-op, and `health_report.rb` excludes it explicitly with
a comment ("waits on an external pipeline, re-polled every cycle").

Two second-order questions, both clean:

- **Does a row leaving `checking_pipeline` look stale to the audit on arrival in
  a stalled state?** No. The AASM transition itself writes a `kind: 'transition'`
  row (`Issue#emit_activity_event!`), so a row entering `reviewing`,
  `fixing_pipeline` or `fixing_discussions` starts its window with a fresh event,
  and from there the #50 heartbeat bounds the silence.
- **The inverse — could a poll event be *hiding* a genuinely stale row?** Only
  for a row in a stalled state, and a stalled row is not polled: `check` is only
  reached through `:check_pipeline`, dispatched exclusively for
  `status = 'checking_pipeline'`. No stalled row receives a poll event.

### Why we still do not rely on that

The analysis above is true today and would make "write nothing between pipeline
status changes" safe. It is nonetheless a **coupling to a fact that lives in
another file**: the day someone adds `checking_pipeline` to `STALLED_STATES` — or
adds a fourth arm to the audit — the silence becomes load-bearing and the failure
is exactly #50's (a row repositioned under a live worker, silently, since the
model runs `whiny_transitions: false`).

So the design picks the option that leaves `without_activity_since`'s **inputs**
unchanged rather than the one that leaves its current readers unaffected.

## Design

Three parts, matching the ticket's three volets.

### 1. Collapse the row instead of appending one

`ActivityLogger.post` already takes `replace_pattern:`, which means exactly "this
entry supersedes its previous occurrence". Today that rule is applied to the
GitLab note only. Apply it to the DB row too:

> **One rule: a note line that is replaced has a DB row that is replaced.**

```ruby
# lib/autodev/activity_logger.rb
def self.post(ctx, issue, key, replace_pattern: nil, **vars)
  entry = build_entry(issue, key, **vars)
  persist_event!(issue, key, entry, vars, collapse: !replace_pattern.nil?)
  ...
end

def self.persist_event!(issue, key, entry, vars, level: 'info', collapse: false)
  payload = JSON.generate(key: key.to_s, vars: vars, message: entry)
  previous = collapse ? last_collapsible_event(issue, key) : nil
  return supersede!(previous, level, payload) if previous

  ActivityEvent.create(issue_id: issue.id, kind: 'danger_claude', level: level,
                       payload_json: payload)
rescue StandardError
  nil
end
```

`supersede!` writes through `update_columns(created_at: Time.current, level:,
payload_json:)`.

Three properties follow, and each is the reason for a choice:

- **`created_at` moves forward.** For a collapsed row, `created_at` means "last
  occurrence", the same thing the note line's leading timestamp means. This is
  what keeps `Issue.without_activity_since` seeing exactly the freshness it sees
  today: a row polled every cycle still has an `activity_events` entry from the
  last cycle. The #50 invariant's inputs are **unchanged**, not merely
  unaffected — no argument about which states are in `STALLED_STATES` is needed
  for the change to be safe.
- **`update_columns` skips callbacks**, so `after_create_commit` does not fire
  and `/stream` no longer receives a frame per poll. That is a fix, not a
  regression: the live feed currently shows one "Interrogation du statut du
  pipeline" line every cycle per watched row. The `/issues/:id` table shows the
  collapsed line with its last-poll timestamp on the next page load, which is the
  same contract the GitLab note has always had.
- **It applies to all four `replace_pattern` call sites**, not just the poll:
  `pipeline_checking` (`PollTracker`), and `pipeline_red`, `pipeline_infra`,
  `pipeline_evaluating` (`FailureHandler`). Those three grow one row per poll on
  a red-stuck ticket for the same reason and were the second-largest contributor
  to the 477 827. One mechanism covers them; a `pipeline_checking`-only special
  case would leave three known leaks open.

**Finding the previous row.** Matching is on `(issue_id, kind, payload key)`.
`payload_json` is always produced by `JSON.generate(key:, vars:, message:)`, so
the key is a literal prefix — `{"key":"pipeline_checking",`. The query is bounded
to the issue's own rows first, which is what makes it cheap: `idx_ae_issue`
(`issue_id, created_at`) seeks the issue, and the `LIKE` filters within it.

```ruby
def self.last_collapsible_event(issue, key)
  ActivityEvent.where(issue_id: issue.id, kind: 'danger_claude')
               .where('payload_json LIKE ? ESCAPE ?', "#{like_escape(%({"key":"#{key}",}))}%", '\\')
               .order(created_at: :desc, id: :desc).first
end
```

`like_escape` escapes `%`, `_` and `\`. `_` matters: activity keys are
snake_case, and an unescaped `pipeline_checking` pattern would also match
`pipelineXchecking`. No such key exists, but the escape costs one line and
removes the class of bug.

**Rejected: a dedicated `dedup_key` column with a partial index.** Faster, and
self-documenting. Not worth a schema change on the hottest-written table in the
DB for a lookup that is already index-bounded to one issue's rows, and the
`without_activity_since` comment argues at length against taxing writes on this
table for read convenience. Recorded as the fallback if the `LIKE` ever shows up
in a profile.

**Rejected: log only on pipeline status change** (the ticket's first suggestion),
tracked via a new `last_pipeline_status` column. It produces cleaner data — every
surviving row is a real event — but it is the option whose correctness rests on
`checking_pipeline ∉ STALLED_STATES`, i.e. on a constant defined in another file
for another reason. The collapse gets the same row-count reduction (one row per
issue per key, bounded) without that coupling. A regression test pins the
exclusion anyway (§Testing), so a future change to `STALLED_STATES` is caught,
but nothing in this design depends on it.

**What does change, and is intended:**

| Reader | Before | After |
|---|---|---|
| `Issue.without_activity_since` | fresh row every poll | fresh row every poll (same) |
| `ActivityEvent.user_visible` | poll rows visible | poll row visible, one instead of N |
| `HealthReport` "Issues bloquées" | never looked at these rows | unchanged |
| `/issues/:id` timeline | 200 poll lines | one poll line + the actual history |
| sparkline `weekly_activity_counts` | ~288 counts/day/watched row | ≤ 1 per row per key |
| `/stream` | one frame per poll | none for a collapsed re-occurrence |

The sparkline change deserves a word: the bar height stops tracking the number of
watched rows and starts tracking work done. That is the metric the card claims to
show.

### 2. An absolute age bound on `checking_pipeline`

**The clock.** A new `issues.checking_pipeline_since` column (datetime), holding
the instant the row entered `checking_pipeline`, `NULL` otherwise. It is written
in one place — a new `after_all_transitions` callback on the AASM machine,
ordered **before** `persist_status_change!` so it lands in the same UPDATE:

```ruby
after_all_transitions :stamp_pipeline_watch!, :persist_status_change!,
                      :emit_activity_event!, :emit_audit_log!

def stamp_pipeline_watch!
  self.checking_pipeline_since = aasm.to_state == :checking_pipeline ? Time.current : nil
end
```

One callback rather than a clear at each of the ~6 exits, because "reset on any
transition" is precisely the semantics the ticket asks for ("N jours **sans
transition**"). A ping-pong `checking_pipeline → fixing_pipeline →
checking_pipeline` therefore resets the clock — correctly: that row *is* moving,
and it is bounded by stagnation detection instead.

Three writers bypass AASM and set `status = 'checking_pipeline'` with
`update_all`: `Issue.reset_for_retry!`, `Issue.revive_stalled!` (both reached
from `recover_on_startup!` and `DormantAudit#revive`). They leave the column at
whatever it was — `NULL`, since the transition **into** the state they were
leaving nulled it. `PollTracker#log_pipeline_poll` therefore lazily stamps a
`NULL` column at the first poll, exactly as it already does for
`pipeline_poll_since`. Two writers, one column, both documented at their site.

`checking_pipeline_since` is deliberately **not** `pipeline_poll_since`.
That column is a display string (`%m-%d %H:%M`) that `clear_pipeline_poll_since`
resets whenever a poll resolves to green or red — including the infra-red case
that stays in `checking_pipeline`. It measures "consecutive unresolved polls",
which is precisely the quantity that never bounds an infra loop.

**Backfill.** The migration seeds the column for rows currently in the state:

```sql
UPDATE issues
   SET checking_pipeline_since = COALESCE(
         (SELECT MAX(created_at) FROM activity_events
           WHERE issue_id = issues.id AND kind = 'transition'),
         created_at)
 WHERE status = 'checking_pipeline' AND checking_pipeline_since IS NULL;
```

The last `transition` event *is* the last transition, so this reconstructs the
real entry instant for every row that has one; `issues.created_at` is the
fallback for the pre-AASM rows. Without it, every row stuck today would get a
fresh N-day grace starting at the release — including #15894 — which would defer
the whole point of the ticket by two weeks. Guarded on `IS NULL` + the status, so
the migration is idempotent and re-running `auto_migrate` is a no-op.

**The threshold: 14 days.** Argued, not picked:

- *It must survive the longest legitimate wait.* A `manual` deploy gate or an
  unrecovered infra failure is resolved by a human. The longest realistic human
  absence on a French team is a two-week holiday, or a company shutdown week with
  a weekend and a *pont* on either side. 7 days abandons live work during August;
  10 days is uncomfortably close to the same case.
- *It must be well below "nobody will ever look at this again".* The ticket's own
  yardstick is six weeks. 42 days is not a safety net, it is the status quo with
  extra steps: at 5 min per cycle that is still ~12 000 polls and ~12 000 GitLab
  round-trips per abandoned row.
- *It must bound the cost.* 14 days caps a watch at ~4 000 poll cycles at the
  default `poll_interval` of 300 s (~10 000 at the 2 min cadence observed in
  production). With volet 1 in place none of those write a row, so the residual
  cost is GitLab reads — bounded, visible, and an order of magnitude under
  #15894's 29 773.
- *It must not fight the other bounds.* `stagnation_threshold` (5 identical
  failures) resolves a red loop in ~25 min; `infra_recheck_max × backoff` (5 × 1 h)
  resolves a recovered-CI case in ~5 h. 14 days sits far above both, so this bound
  only ever fires on cases the specific mechanisms cannot see — which is the
  definition of a safety net.

Setting name `pipeline_watch_max_days`, baked default 14 in `Config::DEFAULTS`,
resolution `@project_config[…] || @config[…] || DEFAULTS[…]` — the same shape as
`infra_recheck_max`. `0` or a negative value disables the bound (the escape hatch
for a project that genuinely gates deploys by hand for a month).

It is **not** added to `Project::SCALAR_CONFIG_KEYS` / `Config::DB_BACKED_PROJECT_FIELDS`.
A DB-backed project's `to_project_config` only emits its DB columns, so the
per-project branch is reachable today only for a YAML-only project — exactly
`infra_recheck_max`'s situation, and stated as such in the docs rather than
implied. Making it DB-backed means a `projects` column, a form field and a
migration for a knob that is a global safety net, not a tuning parameter. Left as
an open point.

**Where the check fires.** After the poll has run, and only if the poll left the
row where it was:

```ruby
def check(issue)
  @dc_issue = issue
  log_pipeline_poll(issue)
  mr = @client.merge_request(@project_path, issue.mr_iid)
  return handle_mr_closed(issue, mr) if mr.state != 'opened'

  dispatch_pipeline(issue, mr.head_pipeline)
  abandon_expired_watch(issue)          # ← new
end
```

Placing it last is the whole point: "the poll ended without a transition" is a
condition, not a status enumeration. `abandon_expired_watch` returns immediately
unless `issue.status == 'checking_pipeline'` (the in-memory AASM object already
carries the new state after `pipeline_green!` / `pipeline_failed_code!`, and
`handle_stagnation` writes it with `issue.update`). So a green pipeline on day 15
still completes normally, a red one still enters the fix cycle, and only a row
that genuinely went nowhere is abandoned. Every non-transitioning branch is
covered without enumerating any of them — including the ones #51 is currently
rewriting.

This also means a GitLab outage cannot abandon a ticket: `check` raises before
reaching the call, and the rescue logs and returns.

> **Correction (Autodev #56).** That last paragraph was true when it was written
> and false by the time it shipped. Autodev #51, developed in parallel and merged
> just before, rescues `Gitlab::Error::ResponseError` *inside*
> `fetch_pipeline_jobs` and returns `nil`, so `dispatch_blocked` logs "jobs
> unavailable, rechecking next poll" and returns **normally** — control reaches
> `abandon_expired_watch` and a 14-day-old ticket was abandoned over a transient
> API error. The same shape already existed on the red path (`fetch_failed_jobs`
> answers an error with `[]` → `handle_no_failed_jobs`), and the two Claude-quota
> deferrals are a third: the row is left in place because we could not act, not
> because the pipeline froze. "The poll ended without a transition" is therefore
> necessary but not sufficient; the bound also requires that the poll read a
> pipeline status. See `PipelineMonitor::WatchBound#poll_inconclusive!`.

**The outcome** mirrors `handle_stagnation`, the existing "delivered, needs a
check" give-up:

```ruby
issue.update(status: 'done', finished_at: Time.current, checking_pipeline_since: nil,
             needs_attention: true, attention_reason: 'pipeline_watch_expired')
apply_label_done(issue.issue_iid)
notify_localized(issue.issue_iid, :pipeline_watch_expired, mr_url:, days:)
log_activity(issue, :pipeline_watch_expired, days:)
```

`attention_detail` stays `nil` — it renders through
`web_errors_attention_detail` ("Job(s) en cause : %{detail}"), so it must carry a
technical token or nothing, and there is no failing job to name here.

New locale keys, `fr` **and** `en`: `notify` `pipeline_watch_expired`, `activity`
`activity_pipeline_watch_expired`, `web`
`web_errors_explain_attention_pipeline_watch_expired`.

`attention_reason` is deliberately **not** `stagnation_pipeline`:
`PollDispatcher#dispatch_infra_recheck` selects exactly that reason and would
re-arm the row. An expired watch is a give-up, not a deferral.

Two properties inherited from `handle_stagnation`, both pre-existing and both
recorded rather than fixed here: the write bypasses AASM (so no `transition`
activity row and no `Audit` entry), and the ticket stays assigned to the autodev
user (no `reassign_to_author`, unlike `green_done_max_reviews`). Changing either
would change three existing give-up paths at once and belongs in its own ticket.

### 3. The purge, as code, never executed here

Framing that makes the whole thing simple: **the purge is volet 1 applied
retroactively.** For each collapsible key, keep the most recent row per issue and
delete the rest. That definition is idempotent by construction (a second run
finds nothing), leaves `/issues/:id` and the timeline coherent (the current poll
line survives), and needs no judgement call about what a "poll row" is.

Delivered as a rake task, `bin/rails autodev:compact_activity_events`, **not** a
migration:

- `config/initializers/auto_migrate.rb` runs migrations at boot, in **every**
  process (supervisor, `bin/rails server`, `bin/jobs start`). A 478 000-row DELETE
  plus a `VACUUM` of a 264 MB file would block three boots, on a schedule nobody
  chose. The ticket requires a human to choose the moment.
- `VACUUM` cannot run inside a transaction, and AR wraps migrations in one.
- A rake task can be dry-run, re-run, and interrupted.

```ruby
# Deletes nothing unless APPLY=1. VACUUM=1 reclaims the file afterwards.
task compact_activity_events: :environment
```

Default is a report. `APPLY=1` performs the deletes in batches of 10 000 (one
SQLite statement per batch, so an interrupt costs at most one batch and the task
is resumable). `VACUUM=1` is a second, separate opt-in because it needs free disk
equal to the DB size and takes an exclusive lock.

#### Manual execution procedure (production, after release)

Run by a human, on `bobette-autodev.netbird.selfhosted`, after the version
carrying this change is installed — never before, or the poll cycle immediately
starts re-inserting rows the old way.

```bash
# 0. Confirm the running version already collapses (volet 1 shipped).
autodev --version

# 1. Report only — no write. Prints per-key: rows examined, rows that would be
#    deleted, rows kept (one per issue).
cd "$(brew --prefix)/opt/autodev/libexec" && bin/rails autodev:compact_activity_events

# 2. Back the database up. Non-negotiable; this is the only undo.
brew services stop autodev
cp ~/.autodev/autodev.db ~/.autodev/autodev.db.bak-$(date +%F)
ls -la ~/.autodev/autodev.db*

# 3. Delete. Idempotent; safe to re-run if interrupted.
APPLY=1 bin/rails autodev:compact_activity_events

# 4. Reclaim the file. Separate step: needs ~264 MB of free disk and an
#    exclusive lock. Skipping it leaves the pages free-but-allocated — correct,
#    just not smaller.
APPLY=1 VACUUM=1 bin/rails autodev:compact_activity_events

# 5. Restart and verify.
brew services start autodev
```

Verification, before and after:

```sql
-- total rows, and the collapsible share
SELECT COUNT(*) FROM activity_events;
SELECT COUNT(*) FROM activity_events
 WHERE kind = 'danger_claude' AND payload_json LIKE '{"key":"pipeline_checking",%';

-- the worst offender named in the ticket
SELECT COUNT(*) FROM activity_events WHERE issue_id = (
  SELECT id FROM issues WHERE issue_iid = 15894);

-- after: exactly one poll row survives per still-watched issue
SELECT issue_id, COUNT(*) FROM activity_events
 WHERE kind = 'danger_claude' AND payload_json LIKE '{"key":"pipeline_checking",%'
 GROUP BY issue_id HAVING COUNT(*) > 1;      -- expected: no rows
```

Then: `du -h ~/.autodev/autodev.db` (expected well under 264 MB after step 4),
`/issues/15894` loads with a readable history, and `/admin/health` is `ok`.

Rollback is step 2's copy. Nothing else in the system reads a superseded poll row.

**What is deleted, exactly**: rows with `kind = 'danger_claude'`, a non-NULL
`issue_id`, a `payload_json` whose key is one of `pipeline_checking`,
`pipeline_red`, `pipeline_infra`, `pipeline_evaluating`, and which are **not** the
newest such row for their `(issue_id, key)` pair. Nothing else — no `transition`,
no `heartbeat`, no system row (`poller`, `error`, `usage`), no other
`danger_claude` key.

## Testing

TDD, one test per claim.

**Collapse** (`test/activity_logger_collapse_test.rb`)
- Two `post`s with the same key and a `replace_pattern` leave **one** row.
- The surviving row carries the newest payload and a `created_at` that moved.
- Two `post`s with the same key and **no** `replace_pattern` leave two rows
  (the default is unchanged).
- Two different keys, both collapsible, do not collapse into each other.
- Two different issues do not collapse into each other.
- The collapse writes no `Web::EventBus` frame.
- A DB failure inside the collapse is still swallowed (the GitLab note is posted).

**The #50 invariant** (`test/pipeline_watch_invariant_test.rb`)
- A row polled repeatedly keeps exactly one poll row whose `created_at` tracks
  the last poll, and `Issue.without_activity_since(1.hour.ago)` does **not**
  select it — the load-bearing assertion: collapse leaves freshness intact.
- The same row, last polled 3 h ago, **is** selected — the scope still works.
- Guard: `checking_pipeline` is absent from `Issue::STALLED_STATES`,
  `HealthReport::ACTIVE_STUCK_STATES` and `PENDING_STUCK_STATES`, so
  `DormantAudit#active_arm` never selects a watched row however quiet it is. This
  test exists to fail loudly if someone adds the state to any of the three.
- `DormantAudit` candidates exclude a `checking_pipeline` row with no activity
  for a week (end-to-end over the real query, not the constant).
- A collapsed poll row is `user_visible` (it is real activity, unlike a
  heartbeat).

**The age bound** (`test/pipeline_watch_bound_test.rb`)
- A watch younger than the threshold is untouched.
- A watch older than the threshold ends `done` + `needs_attention` +
  `pipeline_watch_expired`, with `label_done` applied.
- The GitLab note and the activity entry both fire, carrying `days`.
- A poll that **transitioned** (green → `reviewing`) is never abandoned even
  when the stamp is old — the check reads the post-dispatch status.
- `manual`, `canceled`, `skipped` and "pipeline still running" all reach the
  bound (the branches stagnation detection cannot see).
- `pipeline_watch_max_days: 0` disables it.
- A per-project value overrides the global one.
- A `NULL` stamp is lazily seeded by the poll and does not abandon on the spot.

**The clock** (`test/models/checking_pipeline_since_test.rb`)
- Entering `checking_pipeline` via `mr_created!` stamps it.
- Leaving via `pipeline_green!` / `pipeline_failed_code!` nulls it.
- Re-entering via `discussions_fixed!` re-stamps it (the clock resets on a
  transition).
- The stamp is persisted by the same UPDATE as the status (callback ordering).

**The backfill** (`test/migrations/backfill_checking_pipeline_since_test.rb`)
- A `checking_pipeline` row with transition events is seeded from the newest one.
- A row with none falls back to `issues.created_at`.
- A row in another state is left `NULL`.
- Re-running is a no-op.

**The purge** (`test/tasks/compact_activity_events_test.rb`, in-memory DB only)
- Dry run (default) deletes nothing and reports the counts.
- `APPLY=1` keeps exactly the newest row per `(issue, key)`.
- `transition`, `heartbeat`, system rows and other `danger_claude` keys survive.
- Running twice deletes nothing the second time.
- It never touches a file outside the connected database (asserted by running
  against the in-memory connection only).

## Docs

- `CHANGELOG.md` `[Unreleased]`.
- `CLAUDE.md`: `PipelineMonitor` (the new bound), the Error Handling table (two
  rows), Key Design Decisions ("No blocked state" is now bounded), Configuration
  (the new default).
- `docs/observability.md`: the `stuck_issues` bullet — why `checking_pipeline`'s
  exclusion is still correct now that those rows are quieter, and the collapse's
  effect on the sparkline.
- `docs/usage/autodev-technical-usage.md`: the per-project settings table, the
  error catalog, the state-flow list.

## Constraints

CLAUDE.md: TDD, RuboCop green (`mise x ruby -- rubocop`, never edit
`.rubocop.yml`), Conventional Commits with the subject ending in
`(Autodev #53)`, `CHANGELOG.md` `[Unreleased]` in the same pass, every
user-facing string through `Locales.t` in **both** `fr` and `en`.

Hard rule from the ticket: the purge is **never** executed against
`~/.autodev/autodev.db` or `~/.autodev/autodev_queue.db` from this work. Tests
run against the in-memory test database only.

## Interaction with Autodev #51 (in flight, other branch)

#51 rewrites `PipelineMonitor#dispatch_status` to handle the `manual` status.
This ticket does not touch `dispatch_status`, `handle_green`, `handle_red` or
`infra_skip?`. The overlap is confined to `PipelineMonitor#check`, where this
change appends one line after `dispatch_pipeline(issue, mr.head_pipeline)`. If
#51 also edits `check`, the merge is a two-line textual conflict with no
semantic one: the bound must remain the **last** statement of the method, after
whatever #51's dispatch does.

Semantically the two are complementary and neither weakens the other: #51 removes
`manual` from the set of statuses that go nowhere, this one bounds whatever
remains in that set.

## Out of scope

- Making `pipeline_watch_max_days` a DB-backed per-project field (a `projects`
  column + the edit form). Same status as `infra_recheck_max` today.
- Giving the give-up paths an AASM event so they emit a `transition` row and an
  audit entry. Three existing paths share the flaw; fixing it here would change
  them all.
- Reassigning an abandoned ticket to its author.
- A `dedup_key` column on `activity_events` (see Rejected, §1).
- Any automatic purge or retention policy on `activity_events`. This ticket
  deletes the accumulated backlog once, by hand, and stops the leak; a rolling
  retention window is a separate product decision.

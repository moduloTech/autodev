# Resolving a `manual` pipeline by its blocking jobs (Autodev #51)

Date: 2026-08-11
Ticket: Skynet Autodev #51 — "Le statut de pipeline `manual` n'est pas géré : le
ticket reste surveillé indéfiniment et n'est jamais livré"

Related, **not** implemented here: Autodev #53 ("borner la surveillance de
pipeline dans le temps"), the ultimate safety net for the cases nobody
enumerated. This ticket removes the largest known cause of unbounded watching;
#53 bounds whatever remains.

## Problem

`PipelineMonitor#dispatch_status` knows three outcomes:

```ruby
case status
when *RUNNING_STATUSES then log "... still running, skipping"
when 'success'         then handle_green(issue)
when 'failed'          then handle_red(issue, pipeline)
else log "Pipeline #{status} for MR !#{issue.mr_iid}, skipping"
end
```

GitLab has eleven pipeline statuses. `RUNNING_STATUSES` covers six, `success`
and `failed` two more; `manual`, `skipped` and `canceled` fall into the `else`,
where the monitor logs a line and returns. The row stays in
`checking_pipeline`, and — this is the part that makes it a bug rather than a
deliberate wait — **nothing bounds the wait**. Stagnation detection is fed
exclusively from `handle_red`, so a status that never reaches `handle_red`
never accumulates a signature and never trips `handle_stagnation`.

For `manual` that wait is not merely long, it is infinite by construction.
`manual` is GitLab's status for *"every job that could run has run; what is left
requires a human to press play"*. It is a **terminal** state: no timer, no
runner, no event will change it. On a project whose MR pipelines end with a
manual `deploy_review`, `manual` is the **normal, successful** end state — so
every ticket whose MR goes green ends up parked forever.

Measured on `modulosource/powerpanne/powerpanne/core`, 2026-08-10:

- Pipeline 215229 (MR !11154, ticket #15894): all four blocking jobs green
  (`test`, `static_analysis`, `rubocop_light`, `docker_build`), `deploy_review`
  and `stop_review` `manual`. Read **12 729 times** since 2026-07-23, once every
  ~2 min, each read producing a log line and nothing else.
- Four tickets affected on that project alone — #15894, #16237, #16258, #16341
  — all eventually relabelled `Development::Awaiting CR` **by hand**, by three
  different humans, between one day and four weeks after the block.
- `review_count` stayed 0 on all four: `mr-review` never ran, `label_done` was
  never applied, the author was never reassigned. The work was finished and
  invisible.

The same ticket #15894 had already burned 13 days (07-10 → 07-23) in the same
`else`: 3 676 reads of `canceled`, then 5 711 of `manual`, before a single
`failed` read finally moved it.

## Design

### 1. `manual` is resolved by looking at the jobs, not the roll-up

The pipeline-level status is a roll-up that cannot express "the parts that
gate the merge are green, the parts that gate a deployment are waiting for a
human". The jobs can. So on a `manual` pipeline we fetch the job list and
decide on the **blocking** subset.

**Blocking job** = a job whose result gates the merge:

```ruby
# A job is non-blocking when its failure cannot gate the merge:
#   * allow_failure: true — GitLab itself says the result does not count;
#   * status == 'manual'  — an unplayed manual gate. It has no result yet and
#     will never acquire one without a human, which is precisely why waiting
#     on it is waiting forever.
```

The verdict, on the blocking subset:

| blocking subset | action |
|---|---|
| at least one `failed` | `handle_red(issue, pipeline)` — the existing red path, unchanged |
| anything else (all green, empty, all skipped/created) | `handle_green(issue)` — review, then delivery |

**Why "no blocking job failed" and not "every blocking job succeeded".** In a
`manual` pipeline a blocking job can legitimately sit in `created` or `skipped`:
it is downstream of the manual gate and will never run without the human. Under
"every blocking job must be `success`" those pipelines stay stuck — the bug,
reintroduced one level down. The pipeline status already tells us nothing is
running (a running job would make the roll-up `running`), so the only question
left is whether anything that counts has failed.

**Why not just reuse `fetch_failed_jobs`.** It returns exactly the same set —
`status == 'failed' && !allow_failure`, and a `failed` job is by definition not
`manual`-status — so the verdict could have been one call. It is not, for one
reason: `fetch_failed_jobs` **rescues a GitLab error into `[]`**. That is right
for its own caller (`handle_red` already knows the pipeline is red, so an empty
list means "can't see the jobs, wait"), and catastrophic here, where `[]` would
read as *"nothing failed → deliver"*. A 500 from GitLab must never be the reason
a ticket ships. The new `fetch_pipeline_jobs` therefore returns **`nil`** on an
API error, and `nil` means *skip this cycle*, distinct from `[]` meaning *this
pipeline genuinely has no jobs*. The explicit `blocking_jobs` filter also makes
the concept unit-testable against the ticket's edge cases, and lets the log line
carry the count that the production incident had no way to show.

Pagination: `per_page: 100` without `auto_paginate`, matching
`fetch_failed_jobs` and `DeployReview#find_deploy_review_job`. Consistency with
the two neighbours reading the same endpoint is worth more here than covering a
>100-job pipeline that does not exist on any configured project; if one appears,
all three call sites move together.

### 2. `skipped` takes the same path; `canceled` does not

The ticket asks for a decision on the two other `else` statuses. They look
alike and are not.

**`skipped` → same treatment as `manual`.** A skipped pipeline is one whose
`workflow:`/`rules:` decided nothing should run. It is terminal for the same
reason `manual` is (no runner will ever pick it up) and it carries the same
meaning as *no pipeline at all* — which `dispatch_pipeline` **already treats as
green**:

```ruby
log "No pipeline found for MR !#{issue.mr_iid}, treating as green..."
handle_green(issue)
```

Leaving `skipped` in the `else` means an MR with no CI configured is delivered
instantly while an MR whose CI config skipped itself waits forever, for the same
absence of verification. Routing it through the same blocking-job check makes
those two agree, and costs no special case: all jobs are `skipped`, none is
`failed`, verdict green.

**`canceled` → unchanged: stay in `checking_pipeline`.** This is the documented
"No blocked state" decision in `CLAUDE.md`, and it survives the re-examination:

- A canceled pipeline is an **interrupted** run, not a finished one. Its
  blocking jobs are `canceled`, not `failed` — so the §1 rule would read them as
  green and deliver a ticket whose tests were killed mid-flight. That is the
  exact opposite of the guarantee "review after a green pipeline" exists to
  give, and unlike `manual` there is no reading of the job list that recovers
  the missing verdict.
- Unlike `manual`, the wait usually **does** resolve. Cancellation is nearly
  always followed by a new pipeline — `auto_cancel_redundant_pipelines` on a new
  push, or a human canceling in order to restart — and `head_pipeline`
  re-points to it on the next poll. `manual` has no such successor: it is the
  end.
- The unbounded tail that remains (#15894's 13-day `canceled` episode) is
  precisely what #53 bounds, generically, for every status. Adding a second,
  status-specific timer here would give two competing clocks on the same row.

So `canceled` keeps its behaviour and keeps its documented rationale, now stated
as a comparison against `manual` rather than as a bare assertion.
`CLAUDE.md`'s "Canceled/skipped → stay in `checking_pipeline`" line and the two
matching rows in `docs/usage/autodev-technical-usage.md` are corrected: only
`canceled` still does.

### 3. No new activity-log line

Delivering off a `manual` pipeline is worth explaining to whoever reads the
GitLab note, and it is deliberately **not** written there.

`handle_green` emits `:pipeline_green` after the Claude-quota gate, and that
placement is load-bearing: an activity line appended on *every* poll would blow
past GitLab's 1M-character note cap during a long outage — the reason
`defer_review_for_usage` returns before `log_activity`, and the reason
`FailureHandler` carries `replace_pattern` regexes for its recurring lines. A
new line emitted *before* `handle_green` would sit on the wrong side of that
gate and reintroduce exactly that failure mode; emitting it *inside* would mean
threading the status through `handle_green`, `dispatch_green` and three
finalizers to change one word.

The diagnostic goes to the technical log instead, where it costs nothing:

```
Pipeline manual for MR !11154: 4 blocking job(s), none failed → treating as green
```

Consequence, stated so it is a choice and not an oversight: on GitLab the
ticket reads "Pipeline vert" for a pipeline GitLab paints orange. If that turns
out to confuse people, the fix is a `replace_pattern`-guarded line, not a naked
`log_activity`. No `Locales.t` key is added by this change.

### 4. Where the code goes

- `PipelineMonitor::Constants` — `BLOCKED_STATUSES = %w[manual skipped]` (the
  pipeline is terminal but inconclusive) and `NON_BLOCKING_JOB_STATUSES =
  %w[manual]` (the job cannot gate a merge).
- `PipelineMonitor::ApiHelpers#fetch_pipeline_jobs` — the full job list, `nil`
  on error.
- `PipelineMonitor::JobClassifier#blocking_jobs` / `#failed_blocking_jobs` — the
  filter and the verdict input, next to the other job-classification logic.
- New `PipelineMonitor::BlockedPipeline#dispatch_blocked` — the three-way branch
  (jobs unavailable / a blocking job failed / green). Its own file, matching the
  module-per-concern layout `PipelineMonitor` already uses (14 modules, the
  smallest 18 lines).
- `PipelineMonitor#dispatch_status` gains one `when *BLOCKED_STATUSES` clause.
  The `else` stays, now reached only by `canceled` and any future GitLab status
  — and that is the right default for an unknown status: do nothing, let #53's
  bound catch it.

## Testing

TDD, one behaviour per test, in a new `test/pipeline_monitor_manual_status_test.rb`
built like `pipeline_monitor_infra_recheck_test.rb`: `PipelineMonitor.allocate`,
a `StubClient` answering `pipeline_jobs`, `log`/`log_error` neutered, and
`handle_green` / `handle_red` replaced by recorders so the test asserts the
*routing decision* rather than re-running the whole green or red pipeline.

The cases:

- `manual` + all blocking jobs `success` → green (the production case).
- `manual` + one blocking job `failed` → red, and the pipeline object reaches
  `handle_red` unchanged so the existing triage runs on it.
- `manual` + no jobs at all → green (consistent with "no pipeline → green").
- `manual` + only `manual` jobs → green (the degenerate powerpanne shape: a
  pipeline that is nothing but gates).
- `manual` + a `failed` job with `allow_failure: true` → green (GitLab itself
  says that result does not count).
- `manual` + a `failed` `allow_failure: true` job **and** a `failed` blocking
  one → red (the allowed failure must not mask the real one).
- `skipped` → same path as `manual` (one green case is enough; the branch is
  shared).
- `canceled` → neither `handle_green` nor `handle_red`, and no `pipeline_jobs`
  call at all — the assertion that this ticket did not quietly change it.
- The jobs endpoint raising `Gitlab::Error::ResponseError` → neither green nor
  red. The one that must never regress: an API failure delivering a ticket is
  worse than the bug being fixed.
- `blocking_jobs` directly, on hash-shaped jobs, for the `allow_failure` /
  `manual`-status filter — including a job whose `allow_failure` key is absent
  (must count as blocking; `GitlabHelpers.field` returns `nil`, which is falsey,
  and the fail-safe direction is "blocking").

`success`, `failed` and the running statuses keep their existing behaviour; the
full suite is what proves it.

## Docs

- `CHANGELOG.md` `[Unreleased]`.
- `CLAUDE.md` — the `PipelineMonitor` bullet list gains the `manual`/`skipped`
  case; the "Canceled/skipped" bullet, the Error Handling row and the "No
  blocked state" design decision narrow to `canceled` alone.
- `docs/usage/autodev-technical-usage.md` (French) — the decision matrix and the
  error catalog, same two corrections.

## Constraints

CLAUDE.md: TDD, RuboCop green (`mise x ruby -- rubocop`, never edit
`.rubocop.yml`), Conventional Commits with the subject ending `(Autodev #51)`,
`CHANGELOG.md` `[Unreleased]` updated in the same pass, every user-facing string
through `Locales.t` / `t_web` in both `fr` and `en` (this change adds none — see
§3). `docs/usage/autodev-technical-usage.md` is French.

## Out of scope

- **Bounding pipeline watching in time (#53).** Handled in parallel on another
  branch, and it also touches `PipelineMonitor`. This change deliberately does
  not rewrite the watch loop, the `activity_events` journalling or
  `PollTracker`; it adds one `when` clause and one module. The two overlap
  in `dispatch_status`, in `PollDispatcher#dispatch_pipelines`, and in the
  interpretation of `canceled` — where #53 supplies the bound this spec
  deliberately does not.
- **Playing the manual job.** Autodev could press `deploy_review` itself; it
  already knows how (`Autodev::DeployReview#trigger!`). Out of scope, and
  probably wrong by default: deploying a review environment is a decision with
  side effects outside the MR, and the dashboard already exposes the button for
  a human to make it.
- **`canceled`.** See §2.

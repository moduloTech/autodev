# A job already red on the target branch is not fixed in the MR (Autodev #130)

## Problem

When a merge request's pipeline is red, `PipelineMonitor` sorts the failure into
"infra" or "code" (`JobClassifier#classify_failures`, then Haiku for an uncertain
verdict) and hands every code failure to `PipelineFixer`: one danger-claude call
and one commit per job, in the ticket's merge request. Nothing looks at the same
job on the branch the merge request goes into. A blocking job that is already red
on the target is therefore "fixed" in the ticket's merge request — with code
outside the ticket's scope — or, when Claude cannot fix it, the same signature
comes back and the request is given up under `stagnation_pipeline` for a cause
that is not its own.

## Measurement (production, 08/10/2026)

Source: every `pipeline_fixing` activity row in the production database (318,
all on powerpanne/core, 12/05 → 08/10/2026). For each one the script found the
merge request's last failed pipeline created before the row, its failed blocking
jobs, and the last finished pipeline of the merge request's target branch updated
before the row (`ref=<target>`, status in success/failed/manual/canceled/skipped).
Script and cached GitLab answers: the job's scratch directory, not versioned.

| | fix rounds |
|---|---|
| merge request pipeline found | 304 |
| a failing job also failed, **same name**, on the target | 42 (13.8 %) |
| … and the failure **signature** also matches (rule below) | 6 (2.0 %) |
| … of which every red job was pre-existing | 3 |

Distinct tickets behind the 42 name matches: 12. The six signature matches are
powerpanne 16084 (1 473 failed examples, the same 1 473 on `staging`), 16269
(12 failed examples, the same 12 on `master`), 15349 and 16091 (a 46-second
`test` run ending identically on `staging`), and 16735 (`fatal: hardlink
different from source` during `bundle install`, identical on `master` pipeline
221668). 16735 was given up under `stagnation_pipeline` on 16/09/2026 at 17:34
while `master` was red on that very failure.

The name match alone is not a usable rule. Of the 42, only the 6 above carry a
failure the target accounts for; in 7 the failure is demonstrably another one —
on 01/07, powerpanne 15349's `test` failed three spec examples while `staging`'s
`test` had stopped after 46 seconds naming none — and the other 29 cannot be
compared at all, their traces being truncated. Read by name, all 36 would have
been left unfixed. That is item 4 of the ticket, and it is load-bearing.

Two facts about the traces shaped the signature:

- powerpanne's `test` jobs exceed GitLab's 4 MiB trace limit regularly (the
  trace ends with "Job's log exceeded limit"): the tail of such a trace is the
  middle of the run, not the failure. A truncated trace has **no** signature.
- none of the pipelines sampled exposes a JUnit test report
  (`/pipelines/:id/test_report_summary` answers `count: 0`), so the failed
  examples have to be read from the trace.

## Decision

### Which jobs are pre-existing

A failed blocking job of the merge request's pipeline is **pre-existing** when:

1. the latest **finished** pipeline of the merge request's own target branch
   (the `target_branch` the merge request records — `TargetBranch`'s question 2, not
   the configuration's; read off the field rather than through
   `TargetBranch.named_target`, which raises on a merge request naming none — that
   case is left to the fix path's rebase, which reports it) has a job of the same name whose status is `failed` and
   which is not `allow_failure`; "finished" is any status outside
   `RUNNING_STATUSES` — `manual` included, because that is how `master` ends on
   powerpanne (33 of the 80 distinct target pipelines the measurement read); and
2. the two failures have a **comparable signature** (`FailureSignature`):
   - both traces are read whole; a truncated trace, an empty one, or a trace
     GitLab refused to serve has no signature, and no signature is never
     comparable;
   - lines are normalised: the runner's timestamp/stream prefix, ANSI escapes and
     carriage returns removed; only the `step_script` section is kept (up to the
     runner's `section_end:…:step_script` marker);
   - **examples** signature, when the section names failed examples
     (`rspec ./path:N` or `[bin/]rails test path:N`): the set of `path:N`. The
     merge request's failure is explained when its set is a **subset** of the
     target's — the merge request broke nothing the target had not already
     broken. A superset (one more failing example) is the merge request's own
     failure and is fixed as today;
   - **tail** signature otherwise: the last 5 non-blank lines, ignoring the
     runner's `WARNING: Event retrieved from the cluster` lines, with digits
     replaced by `N` and hex runs of 7+ by `H`, **plus** the set of exception
     classes the section names (`Mysql2::Error::ConnectionError`, `NameError`…).
     Explained when both are equal. The class set was added on review: the
     parallel runner ends every failure that is not a failed example on the same
     five lines ("Tests Failed", "N errors, N examples, N failures", "Took N
     seconds"), so the tail alone let a `NameError` the merge request introduced
     read as the target's database outage. Re-measured with it: still 6 of 42.

The rule errs towards "own": every unknown (no target, no finished pipeline in
the last 20, no matching job, an unreadable or truncated trace, different
signatures) is today's behaviour. Fixing a failure that was pre-existing costs
what it cost before this ticket; leaving unfixed a failure the merge request
introduced would deliver broken work.

### What happens to them

Only on the path that would call `PipelineFixer` — after the pre-triage, the
one retrigger and the infra wait, exactly where `check_stagnation_and_fix` used
to be called. The infra wait calls no fixer and is untouched.

- **Some red jobs pre-existing.** They are taken out of the list handed to
  `check_stagnation_and_fix`: no danger-claude call, no commit for them, and
  they are not in the pipeline stagnation signature. The activity note
  (`activity_pipeline_preexisting`) and one comment on the merge request
  (`pipeline_preexisting_mr_note`) name each job and the target pipeline (id and
  URL). The other jobs are fixed as today.
- **Every red job pre-existing (owner's option c).** Nothing is fixed, nothing is
  counted, no Claude call is made (so no quota gate either). The row stays in
  `checking_pipeline` and **holds** the merge request pipeline
  (`issues.target_red_hold_pipeline_id`). Each later poll recomputes the split on
  that pipeline — without downloading the traces again while the target's latest
  finished pipeline and the red job ids are unchanged (`issues.target_red_hold_key`);
  as soon as one held job is no longer explained by the target's latest finished
  pipeline (another failure, a green job, or evidence that can no longer be
  compared), the merge request pipeline is **retried**
  (`retry_pipeline`, `activity_pipeline_target_recovered`) and the hold is
  released. If the retried run fails again, the target no longer explains it,
  so it is fixed as today — the fix path rebases on the target first, which is
  what picks up the target's own repair.
- **The bound: the hold has its own clock** (owner's decision of 09/10/2026).
  `issues.target_red_hold_since` is stamped by the poll that begins a hold (one
  that holds while no hold is recorded), kept while the hold goes on — a new
  merge request pipeline the target explains too is the same wait on the same
  broken target — and cleared by every poll that compares against the target
  and does not hold: the retry once the target no longer explains every red
  job, and a round that fixes, whether or not some of its jobs were
  pre-existing (a round with none used to keep the hold, so a later hold took
  the stale stamp for its own start and could be given up on its first poll —
  phase-10 review of the alpha-57 lot). A poll that holds is bounded by
  `pipeline_watch_max_days` counted from that stamp (`0` still disables it);
  the ordinary `pipeline_watch_expired` bound on `checking_pipeline_since` is
  unchanged for every poll that does not hold. **A release by retry starts a
  new watch**: the same write that clears the hold re-stamps
  `checking_pipeline_since` to now, because the wait was the target's and the
  retried pipeline is a new one to watch. Without it the retrying poll, which
  does not hold, read the watch's own age — 60 days on the reproduction — and
  gave the row up under `pipeline_watch_expired` on the poll that had just
  concluded; now neither that poll nor the following ones expire the row on
  time spent before or during the hold, and the retried pipeline gets the
  whole bound. A retry GitLab refused releases nothing and restamps nothing. The
  first design had no clock of its own and counted the hold on the watch's age,
  so a row already watched for longer than the bound gave up on the very poll
  its hold began, having waited for nothing — the shape of powerpanne 16735,
  given up on 16/09/2026 while `master` was red on the same `bundle install`
  error. A poll that holds is a poll that read a pipeline status, so it does
  not raise `poll_inconclusive!`. When the bound is reached **on a poll that
  held**, the request is given up under a dedicated reason,
  `target_pipeline_red`, whose public text says the target has explained the
  failure for longer than the bound, names the job(s), the target branch and
  the target pipeline, and says that the failure is not this merge request's.
  The give-up clears `target_red_hold_since` and keeps the held pipeline, so a
  row put back on track later starts a fresh wait if the target is still red,
  and retries the held pipeline if it has been repaired.
- **The way out** (owner's decision of 09/10/2026). No automatic pass re-selects
  a row given up under `target_pipeline_red` — the only re-arm keyed on a
  give-up reason is `dispatch_infra_recheck`'s `stagnation_pipeline` — so a
  retried merge request pipeline would never be reviewed nor delivered. The
  texts give the way out of every other give-up: once the target is repaired,
  put the starting label back and reassign autodev. No automatic re-arm.

The comment on the merge request is posted once per (merge request pipeline,
pre-existing job set) — `issues.preexisting_noted_key` — so a hold that lasts
fourteen days posts it once, and a later fix round whose pipeline still carries
the same pre-existing job posts it once more, for that round.

### Failure handling

- The target pipeline list and its job list go through `GitlabHelpers.answer`:
  an unreadable target aborts the poll with the row untouched, like every other
  read on this path (Autodev #62). An unreadable target is not "the target is
  green".
- A trace: an HTTP answer (404, 403…) is "no signature" — the job is treated as
  own. A request that never completed raises, like `fetch_job_trace`.
- The merge request comment is an announcement: a transport failure is logged,
  the key is not recorded, and the next poll tries again.
- The retry: a failure is logged and the hold is kept, so the next poll retries.

## Contract

- Migration `20261008130001_add_target_red_columns_to_issues`:
  `issues.target_red_hold_pipeline_id` (integer), `issues.target_red_hold_key`
  (string, `"<target pipeline id>:<red job ids>"`), `issues.preexisting_noted_key`
  (string, `"<merge request pipeline id>:<job names>"`).
- Migration `20261008130002_add_target_red_hold_since_to_issues`:
  `issues.target_red_hold_since` (datetime, nullable) — the hold's own clock.
- `PipelineMonitor::FailureSignature` (`lib/autodev/pipeline_monitor/failure_signature.rb`):
  `.of(trace) → nil | [:examples, Set] | [:tail, Array]`,
  `.explains?(target_signature, mr_signature) → Boolean`.
- `PipelineMonitor::PreexistingFailures` (`lib/autodev/pipeline_monitor/preexisting_failures.rb`),
  mixed into `PipelineMonitor`; `fix_own_failures(issue, pipeline, failed_jobs, triage)`
  replaces the direct `check_stagnation_and_fix` call in `triage_and_fix`, around
  `set_aside_preexisting(issue, pipeline, failed_jobs) → own_jobs`.
- `PipelineMonitor::TargetRedNotice` (`lib/autodev/pipeline_monitor/target_red_notice.rb`):
  the activity line, the merge request comment and the give-up.
- `PipelineMonitor::ApiHelpers#latest_finished_target_pipeline`,
  `#comparable_trace`, `TARGET_PIPELINES_SCANNED = 20`.
- Attention reason `target_pipeline_red` with its three sinks:
  `target_pipeline_red` (notification), `activity_target_pipeline_red`,
  `web_errors_explain_attention_target_pipeline_red`.
- Locale keys: `activity_pipeline_preexisting`,
  `activity_pipeline_target_recovered`, `pipeline_preexisting_mr_note`.

## Assumptions

- "Latest finished pipeline of the target" is read over the last 20 pipelines of
  the ref, newest first; a scheduled pipeline without the job masks an older push
  pipeline that has it (then the job is own — today's behaviour).
- The signature rule is calibrated on powerpanne/core (rspec, parallel_rspec,
  docker builds). On a stack whose trace names no failed example, only the tail
  rule applies.
- A held pipeline retried by a human and failing again with the target still red
  stays held; one recovered job is enough to retry, because from then on waiting
  cannot explain every red job.

## Out of scope

- The infra path (`infra_skip?`) and the infra recheck pass.
- Any change to the target branch, or retargeting the merge request.
- A dashboard surface for a held row beyond the existing activity note.

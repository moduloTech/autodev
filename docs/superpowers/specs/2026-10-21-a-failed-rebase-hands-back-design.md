# A failed rebase stops the line and hands it back (Autodev #138)

## The defect

`RepoRebaser#rebase_branch_on_target` answers `:no_op`, `:rebased` or `:failed`.
`:failed` came from two places — `abort_rebase` (`git rebase --continue` refused
after danger-claude's resolution attempt) and the `rescue StandardError` around that
attempt — and in both the branch was left as it was, "stale-but-clean ground" by
design. All three callers discard the symbol:

| Caller | Path | Row state at the rebase |
|---|---|---|
| `IssueProcessor::GitOperations#resolve_branch` | re-implementation on a reused branch | `cloning` |
| `MrFixer::FixCycle#run_fix_cycle` | discussion fix round | `fixing_discussions` |
| `PipelineMonitor::FailureHandler#prepare_work_dir` | pipeline fix | `checking_pipeline` |

So implementation, fixes and the review that follows them ran on a base the target
had left behind, and nothing said so outside `production.log`.

Measured (MR powerpanne/core !11262, PP#12935, A#135, 09/10/2026): rebase on
`origin/master` at 12:30:48, `Rebase --continue failed; aborting rebase. Output:
app/controllers/companies/sites_controller.rb: needs merge` at 12:33:41, the
implementation pushed at 12:42 on a `staging` base 865 commits behind `master`; the
same at 17:30 (pipeline fix) and on 10/10 at 04:02 (discussion round 2). The
reviewer had asked for `Jobs::MissionCreator`; it does not exist on that base, so
nothing was done and the automatic review asserted it did not exist.

Measured by the batch on production logs: the line appears 2 times in
`production.log.20261015-063000` and 28 times in `production.log.20261016-063946`.

## Decision (owner)

A failed rebase **stops** the line and hands it back. The danger-claude conflict
resolution is kept: only its failure stops.

## Design

### The rebaser raises, it no longer returns `:failed`

`RebaseConflictError < AutodevError` (`lib/autodev/errors/rebase_conflict_error.rb`)
carries `branch`, `base` and `files` (the conflicted paths). The rebaser raises it
where it used to return `:failed` after `git rebase --continue` refused. A symbol is
what all three callers discarded; an exception cannot be discarded by a caller that
never heard of it — the generic `rescue StandardError` of each fix boundary would
catch it, which is why each boundary names it above that clause (below).

It is **not** an `ApiUnavailableError`: nothing is unavailable, and the family's
behaviour (leave the row, re-read next cycle) is precisely the loop to avoid — the
next cycle would clone, conflict and pay another danger-claude call.

`rebase_branch_on_target` now answers `:no_op` or `:rebased`, or raises.

### Which files

`git diff --name-only --diff-filter=U`, read **before** `git rebase --abort` (which
erases the information). Read twice: once when `git rebase` first stops (the files
danger-claude is asked to resolve), once when `--continue` refuses. The second is
named when it is not empty (it is what is still unmerged, possibly on a later commit
of the replay); otherwise the first. In the measured case both are
`app/controllers/companies/sites_controller.rb`. An empty list (git refused for a
reason that left nothing unmerged) is still a stop, and the comment says no file was
listed. The `--continue` output itself stays in the log only — it is git's text
about a client's repository and is not published.

### A danger-claude crash is not a conflict verdict

The `rescue StandardError` around the resolution attempt used to answer `:failed`.
It now aborts the rebase (as before, so the tree is clean) and **re-raises the
original error**: `RateLimitError` already did; `AuthenticationError`, a container
failure or a timeout now reach the boundary's existing handler (`error` + retry,
or the 401 path), which is what every other danger-claude crash on these paths
already gets. Reason: Autodev #107 measured that a tool outage read as a verdict
abandons healthy requests (nine hours of Docker refusals spent five review
failures on powerpanne 16030). Abandoning on a crash would be the same error. The
invariant of this ticket still holds: a raise ends the round, so nothing is
implemented, fixed, pushed or reviewed on the stale base.

The push that follows a resolved conflict is also out of that rescue now: a push
failure there used to become `:failed` (and the work ran on), while the same failure
after a clean rebase propagated. Both propagate.

### The three boundaries stop the line

`RebaseConflictStop#stop_on_rebase_conflict(issue, error)` (one module, included by
`IssueProcessor`, `MrFixer`, `PipelineMonitor`):

1. `abandon_issue(issue, :rebase_conflict, detail: <first five files>, branch:, base:, files:)`
   — `done`, `needs_attention`, `attention_reason = 'rebase_conflict'`,
   `label_attention`, the ticket handed back (`Issue#handback_target`), one ticket
   comment, one activity line;
2. when the row carries a merge request, one comment **on the merge request**
   (`rebase_conflict_mr_note`) naming the files, the base and how to resume —
   the reviewer reads the merge request, not the ticket. Posted through
   `after_conclusion`: the row is already `done`, a lost comment costs that comment.

Where it is caught: in the generic handler each path already routes unexpected
errors to, as its first test after the 401 one and **before any write** — the
precedent is `StaleTransitionError`, dispatched the same way:

- `PipelineMonitor::ErrorHandler#handle_failure_error` (reached from
  `FailureHandler#attempt_fix`'s `rescue StandardError`);
- `MrFixer::ErrorHandler#handle_fix_error` (from `FixCycle#execute_fix_cycle`);
- `IssueProcessor::ErrorHandler#handle_process_error` (from `IssueProcessor#process`).

So none of them marks the row `error`, schedules a retry, or posts its generic
failure comment: a retry would meet the same conflict.

The stagnation signature is not written (the pipeline one is written after
`clone_and_fix` returns, the discussion one after the round's corrections — neither
is reached), and no counter moves: the give-up is immediate, not bounded. One
occurrence is enough because the failure is not transient — danger-claude already
had its attempt, and the next cycle would replay the same conflict on the same
commits. That is what distinguishes it from `target_branch_missing`, which counts
because a fetch can fail transiently.

### The implementation path (decision)

`resolve_branch` rebases a **reused** branch: a re-implementation of a delivered
ticket (a merge request exists — the motivating case at 12:30) or a run that stopped
before `create_merge_request` (no merge request). Both stop. The row is in
`cloning` there, so `cloning` joins the sources of the `abandon` event. Without a
merge request there is no MR comment; the ticket comment carries everything.

### How a human resumes

The comments say it: rebase the branch on `origin/<base>` by hand, resolve the
listed files, push (force-with-lease), then repose the starting label and reassign
autodev. That is the ordinary label resume (`PollRouter#reenterable?` → `done` is
re-enterable): with an open merge request `ResumeHandler#reenter_destination` sends
the row to the pipeline check, or to a re-implementation when a human commented on
the ticket since; without one, to a re-implementation, where `resolve_branch`'s
rebase is now a `:no_op`.

### The review

With the stop, no review runs on a branch whose rebase failed: the fix rounds and
the re-implementation that would precede it end at the boundary, nothing is
pushed, and the row is `done` + `needs_attention`, outside `dispatch_pipelines`'
population (`checking_pipeline`) — the only pass that reaches `launch_review`.
`test/a_failed_rebase_hands_back_test.rb` pins it on the pipeline path (the review
is not launched) and on the fix path (the row is not in `checking_pipeline`).

Out of scope, stated so it is not read as covered: a branch on which **no rebase
was attempted** (a first review right after a fresh implementation) is reviewed on
whatever base it was cut from. That is ordinary drift, not a failed rebase, and the
merge request's own diff is computed by GitLab against the merge base.

## Contract

- `RebaseConflictError(branch:, base:, files:)` — `AutodevError`.
- `RepoRebaser#rebase_branch_on_target` → `:no_op | :rebased`, raises
  `RebaseConflictError`, `MissingTargetBranchError`, or the resolution attempt's own
  error.
- `RebaseConflictStop#stop_on_rebase_conflict(issue, error)`.
- `Issue` `abandon` event: sources `cloning checking_pipeline fixing_discussions reviewing`.
- Attention reason `rebase_conflict`; locale keys `rebase_conflict`,
  `rebase_conflict_mr_note` (notifications), `activity_rebase_conflict`,
  `web_errors_explain_attention_rebase_conflict` — fr and en.
- No migration, no column, no setting.

## Assumptions

- A refused `--continue` after danger-claude's attempt is permanent for this commit
  set; nothing on the next cycle would differ.
- The conflicted file paths may be published on the ticket and the merge request:
  both are on the same project, readable by the same people as the repository.
- `abandon` fired by hand from the dashboard on a `cloning` row is acceptable (the
  event is already offered from three other states).

## After deploy

Production could not be read when this was written (NetBird down on the
workstation: `netbird status` → `NeedsLogin`), so the distinct-row count asked for
is replaced by the nearest measurement GitLab gives: on 21/10/2026, of the **74**
open merge requests autodev authored on powerpanne/core (all targeting `master`),
**26** are `has_conflicts: true` (fast/core: 0 open). Each of those whose row
reaches a write action (a red pipeline, a discussion round, a re-implementation)
will stop at that action under `rebase_conflict` unless danger-claude resolves the
conflict — an upper bound, since most of them are `done` rows waiting on a human
and never rebase again. The owner should run, once NetBird is up:

```
ssh bobette-autodev.netbird.selfhosted 'cd ~/.autodev/log && grep -h -B40 "Rebase --continue failed" production.log* | grep -o "issue #[0-9]*\|MR ![0-9]*" | sort -u'
```

and expect those rows on the "Issues bloquées" / attention tab at their next write
action.

## Owner may reverse

1. **A danger-claude crash during resolution → error + retry, not a hand-back.**
   Other option: treat it as a failed resolution and abandon. On the motivating case
   nothing changes (danger-claude returned; `--continue` refused). On a Docker outage
   the other option would hand back every ticket that hit a conflict during it.
2. **The implementation path stops too, with or without a merge request.** Other
   options: without a merge request, cut a fresh branch from the target and drop the
   previous work (silent loss of commits nobody reviewed), or continue on the stale
   base (today's defect). On the motivating case (a merge request exists) only the
   stop prevents the 12:42 push on a base 865 commits behind.
3. **One occurrence stops; no count.** Other option: bound it by
   `stagnation_threshold` like `target_branch_missing`. On the motivating case that
   would have paid four more danger-claude resolutions of the same conflict and four
   more clones before stopping.

# A network cut is not a fix failure (Autodev #125)

Date: 2026-09-28
Ticket: Skynet Autodev #125 — "Une coupure réseau vers GitLab pendant une
correction de MR est annoncée comme un échec sur le ticket", plus its comment of
2026-09-25 on `dormant_recheck_count`.

## Problem

`MrFixer::FixCycle#execute_fix_cycle` and `PipelineMonitor::FailureHandler#attempt_fix`
already separate the two cases: an `ApiUnavailableError` is re-raised to the
round's boundary, which leaves the row where it is for the next cycle (Autodev
#62, #67); everything else lands in `rescue StandardError`, i.e. `error`, no retry
stamp, and a public "échec correction MR" / "pipeline_fix_error" comment.

A transport failure only becomes an `ApiUnavailableError` when the call goes
through `GitlabHelpers.answer`. Several calls under those two rounds do not, and
guard themselves with `rescue Gitlab::Error::ResponseError` — which does **not**
catch `Net::OpenTimeout` (`Net::OpenTimeout < Timeout::Error < RuntimeError`,
verified under Ruby 4.0.1). The cut escapes to `rescue StandardError`.

### Measured in production (read-only, 2026-09-28)

`gitlab_transport_failures` (Autodev #96) names the endpoint of every cut:

| Row | When (UTC) | Endpoint that timed out | Local guard |
|---|---|---|---|
| A#139 | 2026-09-25 06:55:03 | `resolve_merge_request_discussion` | `rescue Gitlab::Error::ResponseError` (`MrFixer#resolve_discussion`) |
| A#144 | 2026-09-25 12:29:02 | `issue_links` | `rescue Gitlab::Error::ResponseError, NoMethodError` (`IssueFormatter.append_links`) |
| A#136 | 2026-09-04 09:37:05 | `issue_links` | same, under the pipeline fix |

Correlating every `error` activity event whose payload holds a transport class
with the failure recorded in the same 3 seconds: **31 events on 15 rows since
2026-09-02**. Of the 22 that can be attributed (the table starts on 2026-09-03):
`issue_links` 7 — every one of its 7 recorded cuts —, `create_issue_note` 5,
`resolve_merge_request_discussion` 3, `user` 2, `edit_issue` 2,
`merge_requests` 1, `job_trace` 1, `issue` 1.

### Two diagnostics that cannot say which call cut

1. `error_message` keeps `backtrace.first(10)`. For an error raised in a gem those
   ten lines are all net-http, httparty and gitlab, ending at best on
   `gitlab_request_counter.rb:85`. Measured on A#136 and A#139: no frame of
   autodev's own call site survives.
2. `GitlabTransportFailure#caller_location` is `caller_locations(2, 1)` taken
   inside the proxy, and it is **always**
   `…/lib/autodev/gitlab_request_counter.rb:50:in 'GitlabRequestCounter#method_missing'`
   — every row read on 2026-09-04 and 2026-09-25. The column meant to answer
   "which call" has never answered it.

### The counter the comment adds

`dormant_recheck_count` is written in one place, `DormantAudit#audit`, which
increments it. Neither the label resume (`ResumeHandler#reenter_via_pipeline_check`,
`#reenter_via_reimplementation`, which reset every other budget including its
sibling `infra_recheck_count`) nor the Reset button (`Issue.reset_for_retry!` with
`reset_budget: true`) touches it. A#139, A#144 and A#148 are at 3/3 in
production: their next dormant episode ends in `dormant_exhausted` without a
single recovery.

## Decisions

### D1 — per call site, not at the client (the ticket's option 4 is rejected)

Converting transport errors in `GitlabRequestCounter` would change what 14
`rescue ApiUnavailableError` boundaries receive across the whole application
(IssueProcessor, reviewers, dispatch passes), for a ticket about two rounds.

A boundary-level safety net in `execute_fix_cycle` / `attempt_fix` is rejected
too: those blocks contain clones, file writes and spawns, so an
`Errno::ENOENT` from a missing binary would read as "GitLab is down" and retry
forever in silence — the lie `TRANSPORT_ERRORS`' own comment forbids ("it is
exactly as broad as the block").

So each call is fixed where it is, and **no shared writer is widened**. The plan
adversary measured why: `IssueNotifier#notify_issue` is also how
`QuestionHandler#post_answer` and `SpecChecker#notify_clarification_questions`
deliver their answer, and both transition the row right after it. A cut there
raises today, so the answer is retried. If `notify_issue` swallowed the cut, the
ticket would be marked answered with no answer posted.

Three rules:

- **A read** keeps its HTTP behaviour unchanged, and a request that never
  completed becomes an `ApiUnavailableError`: the round ends at its boundary and
  is replayed next cycle (Autodev #62).
- **A non-verdict write owned by the round** (a thread resolution, a pipeline
  retrigger, a handback) swallows the whole transport family and returns what
  actually happened. Precedent: `ExternalState#notify_stop` (Autodev #115), with
  the classes spelled out so the #62 scanner recognises the clause (a
  `*TRANSPORT_ERRORS` splat is its blind spot, Autodev #119).
- **What a round announces after it has already moved the row** goes through
  `IssueNotifier#after_conclusion`, which swallows the family and logs it. The
  transition is the verdict, and the announcement cannot undo it.

| Call | Kind | After this change |
|---|---|---|
| `IssueFormatter.append_links` (`issue_links`) | read, prompt context, before push | HTTP and `NoMethodError` are swallowed as today (the capability gap of #67). A cut raises `ApiUnavailableError` (`what: :issue_links`) and the round is replayed |
| `PipelineMonitor::ApiHelpers#fetch_job_trace` (`job_trace`) | read, prompt context, before push | HTTP: the placeholder as today, built from GitLab's own message. A cut raises `ApiUnavailableError` (`what: :job_trace`) |
| `MrFixer#resolve_discussion` | write, before push | the family is swallowed and logged, and it returns whether the thread was resolved. `fix_single_discussion` counts only a resolved thread, so the success line stays true (#79). The thread stays open and the next round re-reads it |
| `FailureHandler#retrigger_if_needed` (`retry_pipeline`) | write | the family answers `false` as HTTP already does. The count is not advanced and the triage continues |
| `IssueNotifier#hand_ticket_back` | write | the family answers `false`, so the abandon notice does not claim a handback that did not happen (#60) |
| `MrFixer#report_round` notice, `PipelineFixer#notify_fix_pushed` notice, `IssueAbandonment#abandon_issue` label + announcement | writes after `discussions_fixed!` / `pipeline_fix_done!` / `abandon!` | wrapped in `after_conclusion` |

Deliberately unchanged: `notify_issue`, `assign_to_self`, `LabelManager` (shared
with paths where the write is the deliverable), and every IssueProcessor path.

Already safe, verified: `ActivityLogger.post` and `#log_activity`,
`DiscussionSnapshot.capture` and `ScreenshotUploader.process` all rescue
`StandardError`.

**After the push.** `MrFixer#complete_discussion_fix` fires `discussions_fixed!`
and then posts the success notice. `PipelineFixer#complete_fix_round` fires
`pipeline_fix_done!` and then notifies. A cut on that notice used to reach
`rescue StandardError`: the row, whose correction was already pushed, went to
`error`, with a comment declaring the correction failed. Now a cut after the
push costs the notice and nothing else.

### D2 — `error_message` keeps autodev's frames

New `BacktraceExcerpt` (`lib/autodev/backtrace_excerpt.rb`): the first 10 lines
as today, followed by up to 10 more lines that belong to autodev — under the
application root and not under `vendor/` — which the head did not already show.
Used by the three `error_message` writers (MrFixer, PipelineMonitor,
IssueProcessor — the third has the same `first(10)`). The log line uses the same
excerpt.

`GitlabRequestCounter` records as `caller_location` the first autodev frame
outside its own file, taken from the same helper.

### D3 — `dormant_recheck_count` is a budget like the others (owner's decision, 2026-09-28)

Reset `dormant_recheck_count: 0, dormant_recheck_at: nil` on the two human
gestures that already reset the other budgets:
- the label resume, i.e. `ResumeHandler#reenter_via_reimplementation`, and
  `#reenter_via_pipeline_check` when `origin` is nil;
- the Reset button, i.e. `Issue.reset_for_retry!` with `reset_budget: true`.

`reenter_via_pipeline_check` has two more callers, and neither resets the counter:
- `resume_recovered_infra`, which is automatic;
- `ReviewArrearsSweep`, which is outside the owner's decision. **Not** on "progress" (a transition out of `error` or of a
dormant state): the cap exists so a row that keeps falling dormant stops
consuming GitLab reads (#47, #103), and a reset on every recovery would reopen
that loop. `DormantAudit`'s own successful revive leaves the counter as it is.

## Out of scope

- IssueProcessor's own GitLab writes outside `notify_issue`: its `error` path is
  re-armed with a bounded backoff, unlike the two fix rounds.
- `RateLimitDetector` not recognising "weekly limit": Skynet #127, same lot.
  Both tickets touch `lib/autodev/mr_fixer/error_handler.rb`.
- The #119 scanner blind spot itself.

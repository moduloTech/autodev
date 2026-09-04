# The pass writes the state it selects on (Autodev #110, #111, #102)

Date: 2026-09-04
Tickets:
- Skynet Autodev #110 — "Le recheck infra dépense son budget à l'enfilement et
  non à la tentative : cinq enfilements d'un même cycle brûlent le plafond de 5
  en quatre minutes"
- Skynet Autodev #111 — "Le résidu `next_retry_at` survit à la sortie d'erreur :
  `perform_retry_errored` n'efface pas l'estampille que `perform_retry_stuck`
  efface"
- Skynet Autodev #102 — "Une demande en erreur n'est jamais contrôlée pour
  reprise en main : autodev la relance sur un ticket qu'un humain a repris"

Three tickets, one rule, one branch. **A pass writes the state it selects on; the
work it triggers does not.** #110 breaks the rule and bleeds. #111 is the same
rule stated on the other side — an entry into `error` writes the retry decision,
leaving `error` erases it. #102 is the pass that never asks its question at all,
and it lives in the method #111 edits, so separating them would mean reading
`perform_retry_errored` twice.

## Problem

### #110 — the budget is spent on enqueue, and nothing reserves the row

`PollDispatcher#dispatch_infra_recheck` (`app/services/autodev/poll_dispatcher.rb:444`)
enqueues a `:recheck_infra` job without writing anything.
`infra_recheck_count` and `infra_recheck_at` — the two columns
`fetch_infra_recheck_candidates` (`:452`) filters on — are written only by the
job, in `PipelineMonitor::InfraRecheck#record_recheck_attempt`
(`lib/autodev/pipeline_monitor/infra_recheck.rb:108`). Every poll cycle passing
between the enqueue and the execution re-selects the same row.

Measured in production on 04/09/2026, powerpanne/core#16030 — the very request
that motivated the alpha 53 lot. The first four attempts spaced themselves an
hour apart exactly as the backoff intends (02:48, 03:50, 04:52, 05:54). Then, in
eighty seconds, five enqueues announced the same attempt:

```
06:59:16  Enqueued infra recheck for issue #16030 (attempt 5)
06:59:24  (attempt 5)
07:00:02  (attempt 5)
07:00:06  (attempt 5)
07:00:33  (attempt 5)
```

The five jobs then ran in sequence: `attempt 5/5`, `6/5`, `7/5`, `8/5`, `9/5`.
The code logs its own overrun and does nothing about it.

`infra_recheck_count` is 9 for a cap of 5, so the row is selectable by no
automatic pass any more: `fetch_infra_recheck_candidates` requires
`infra_recheck_count < infra_recheck_max`, `DormantAudit` covers `pending`,
`error` and `STALLED_STATES` while the row is `done`, and `ReviewArrearsSweep`
targets `pipeline_watch_expired` rather than `stagnation_pipeline`. It still
carries `infra_recheck_at = 04/09 08:03`, a stamp nobody will honour.

The harm is not the parking — the ticket went back to its author with
`Development::StandBy`, which is the intended behaviour and validates Autodev #98
in the field. The harm is the **lost watch window**: a budget meant for five
looks an hour apart at a recovering CI was spent in four minutes. A runner
failure repaired within the hour would not have been caught.

### Why this pass and not its neighbours — verified, and it is the whole design

`dispatch_pipelines` (`:271`), `dispatch_discussions` (`:280`) and
`dispatch_retries` (`:392`) have exactly the same shape, and `dispatch_discussions`
was observed doing it on 03/09 at 21:23: four "Enqueued discussion fix for issue
#16030 (round 1)" in fifteen seconds. None of them bleeds, and the reason is
`IssueProcessJob::DISPATCHED_FROM` (`app/jobs/issue_process_job.rb:67`, Autodev
#61): each action declares the row state it was dispatched from, and the job
skips when the row has moved on. The work itself moves the row out of that state,
so the duplicate finds nothing to do.

- `retry_stuck` requires `pending`; `IssueProcessor#process` leaves `pending`.
- `retry_errored` requires `error`; `retry_pipeline!` / `retry_processing!` leave
  `error`.
- `check_pipeline` requires `checking_pipeline`; `fix_discussions` requires
  `fixing_discussions`.
- `recheck_infra` requires `done` — **and a recheck that finds CI still broken
  leaves the row `done`.**

That is the discriminator. The state guard is not a reservation, and it only
looks like one when the work happens to change the state. `recheck_infra` is the
one pass whose precondition survives its own work, so it is the one pass where a
duplicate costs a real budget unit. The fix therefore cannot be another state
guard: it has to be a reservation written on the selection criteria themselves —
see Design §1 for which column carries it, and why not both.

### #111 — the two recovery paths treat the stamp differently, for no written reason

In `app/jobs/issue_process_job.rb`:

- `perform_retry_stuck` (`:191`) clears `next_retry_at` as its first statement.
- `perform_retry_errored` (`:183`) clears `error_message` and `started_at`, and
  leaves `next_retry_at` in place.

Autodev #103's fix handled the *entry* into `error` — `safe_mark_failed!` now
requires the retry decision — and not the exit. Observed again on 03/09/2026 on
powerpanne/core#16030: the row carried `next_retry_at = 03/09 18:30`, in the past,
while no longer in `error`.

It is not urgent, and the spec should say so rather than inflate it. `fetch_retryable`
(`:399`) filters `status IN ('error','pending')`, so a residue only survives on
rows the retry pass does not look at. But `PollDispatcher.retryable?` (`:45`)
reads exactly three things — `retry_count`, `next_retry_at` non-nil, and its
comparison to now — so a stale stamp makes the row a candidate the instant its
status passes back through `error` or `pending`, with no new `mark_failed` having
decided that retry. The protection holds only by the status filter, and nothing
in the code says that is intentional.

### #102 — an `error` row is never asked whether a human took the ticket back

`dispatch_unassignment` (`:291`) — the pass that asks "did somebody take this
ticket back?", by unassignment or by moving the workflow label — sweeps
`ACTIVE_STATUSES` only, and `error` is not in it (`:23`).

An errored request is therefore never checked, and `error` is precisely the state
where a human takeover is most likely: autodev failed, the ticket carries
`label_attention` or stayed on `label_doing`, and someone who sees that moves it
into their own column.

`dispatch_retries` then relaunches the row. It goes back to `checking_pipeline`
or `pending`, `restore_working_label` (`app/jobs/issue_process_job.rb:216`)
re-applies autodev's working label, and only at the **next** cycle — the row
being active again — is the takeover possibly detected. Meanwhile autodev has
written on a ticket somebody was holding, and a successful retry can deliver over
that person's work. The pass order makes it worse: `dispatch_unassignment` runs
*before* `dispatch_retries`, so the relaunched row is not re-examined until the
cycle after.

Alpha 52 closed an aggravation of this (#98 made the retry erase the only evidence
of the takeover; scope clearing became opt-in again). The evidence survives now.
The one-cycle hole does not.

## Design

### 1. `dispatch_infra_recheck` reserves the row it enqueues

**What the reservation writes, and what it deliberately does not.** The row is
reserved by moving `infra_recheck_at` — the column the race is actually lost on —
and **not** by incrementing `infra_recheck_count`.

That is narrower than "the dispatcher writes both columns it selects on", and the
reason is an invariant this pass already holds. `record_recheck_attempt` is called
only `if verdict == :spend` (`lib/autodev/pipeline_monitor/infra_recheck.rb:31`),
and the two verdicts that read nothing — a GitLab error and an MR in a transient
state — return without spending, with the reason written on the `rescue`:

> a cycle that could not read anything must not re-arm the row, and — like
> `check_stagnation_and_fix` — must not spend one of the bounded attempts either,
> or an outage burns the whole budget without ever having looked at a pipeline.

Spending at enqueue would break exactly that: five minutes of GitLab being
unreachable would consume the whole watch budget, which is the harm this ticket
is about, reintroduced from the other side. So **point 2 of the ticket is
answered explicitly: the spend lives with the attempt, because an attempt that
looked at nothing is not an attempt.** The dispatcher owns the clock; the job
owns the count. The defect was never that the count lived in the job — it was
that *nothing* reserved the row, so the clock never moved between two cycles.

The conditional UPDATE repeats the predicate of `fetch_infra_recheck_candidates`
and enqueues only if it matched a row:

```ruby
reserved = ::Issue.where(id: issue.id)
                  .where(status: 'done', needs_attention: true,
                         attention_reason: 'stagnation_pipeline')
                  .where('infra_recheck_count < ?', infra_recheck_max)
                  .where("infra_recheck_at IS NULL OR infra_recheck_at <= datetime('now')")
                  .update_all(infra_recheck_at: next_backoff_stamp)
return if reserved.zero?
```

`update_all` issues one SQL UPDATE and returns the number of affected rows; zero
means another cycle got there first and this one must not enqueue. Re-stating the
whole predicate rather than only `id` is what makes it a compare-and-set: two
cycles racing on the same row cannot both match, because the second one's
`infra_recheck_at` no longer satisfies the predicate.

`Issue.reset_for_retry!` (`app/models/issue.rb:409`) is the in-repo precedent for
this shape — a `where(...).update_all(...)` whose return value is the count that
matters. This is also the narrow, one-column answer to the caveat written at
`app/models/issue.rb:280`: `refuse_stale_transition!` is explicitly *not* atomic
and says so, and says that making it atomic would mean optimistic locking on
every write path. Nothing here asks for that. One conditional UPDATE on the two
columns one pass selects on is not the general problem, and the comment on
`dispatch_infra_recheck` should say which of the two it is, so a future reader
does not mistake it for a precedent for the larger change.

**The models are ActiveRecord, not Sequel.** The comment at the head of
`PollDispatcher` (`app/services/autodev/poll_dispatcher.rb:15`) still says
"The Sequel models (`Issue`, `ActivityEvent`) are dynamically defined by
`Database.build_model!`", which stopped being true when `Issue` became an
`ApplicationRecord` (`app/models/issue.rb:12`); the same file rescues
`ActiveRecord::RecordNotUnique` twenty lines below. Correct it while in the file —
a stale declaration about which ORM a query targets is exactly the kind of
unverified statement Autodev #73 exists for, and it is what would send an
implementer to `Sequel.expr`.

`record_recheck_attempt` stops writing `infra_recheck_at` — the dispatcher owns
that clock now — and keeps writing `infra_recheck_count` on a real attempt. Its
log line stays true for the first time: one reservation, one job, one attempt.

**Where each column lives is stated in one place**, in a comment on
`dispatch_infra_recheck` that a future reader hits before the job: the dispatcher
owns `infra_recheck_at`, the job owns `infra_recheck_count`, and the rule that
ties them is that a cycle which read nothing spends nothing.

The backoff interval is unchanged (`infra_recheck_backoff_seconds`), only its
writer moves. `PollDispatcher` must read it from the same config keys
`InfraRecheck#infra_recheck_backoff_seconds` reads, and the two must not grow two
copies of that lookup — `infra_recheck_max` is already duplicated between the two
files, and this ticket should not add a second instance of the same duplication.

### 2. `record_recheck_attempt` refuses to exceed the cap

Even with reservation, the cap becomes a guard and not only a filter: a write
beyond `infra_recheck_max` is refused and logged at warning level. A logged
overrun with no consequence is the symptom that should have raised the alarm on
04/09, and leaving that shape in place would preserve the thing that made the
defect invisible for a whole night.

### 3. `perform_retry_errored` clears `next_retry_at`

One line, symmetric with `perform_retry_stuck`, plus the rule written where it
will be re-read — as a comment on the two methods, not in a document nobody
opens:

> Entering `error` writes the retry decision (`mark_failed`); leaving it erases
> it. `PollDispatcher.retryable?` reads the stamp and nothing else, so a residue
> is a decision nobody took.

Callers are checked for anything relying on the stamp surviving; `fetch_retryable`
and `DormantAudit#error_arm` are the two readers, and both want it gone.

**Existing rows carrying a residue are left alone, deliberately.** They are all
outside `fetch_retryable`'s status filter, cleaning them is a production write
with no benefit, and the invariant holds from here on. The count is reported in
the changelog so the decision is visible rather than silent.

### 4. The question is not rewritten — it is reached from the job

`ExternalState#stop_on_handover(issue, gl_issue)`
(`app/services/autodev/external_state.rb:61`) already **is** the pair this needs:
it asks `LabelHandover#verdict`, and on a verdict it posts the notice and closes
the row through `close_row!`, the module's single terminal write. `error` is in
the `close` event's `from` list (`app/models/issue.rb:191`), so `may_close?` — the
method's own precondition — holds from there.

So no new definition of the question, and no PORO wrapping one. The gap is only
that `ExternalState` is a mixin for poll-cycle services carrying `@client`,
`@path`, `@project_config` and `@logger`, and `IssueProcessJob` is not one of
those. A thin `Autodev::HandoverStop` (`app/services/autodev/handover_stop.rb`)
includes `ExternalState`, sets those four ivars in its initializer and exposes
nothing of its own. Twelve lines, no logic, and therefore nothing that can drift
from `PollDispatcher`'s answer — which is the whole point, and the same reason
Autodev #93 extracted `UntouchedSinceGiveup` rather than writing the question
twice.

### 5. `perform_retry_errored` asks before it relaunches

Order matters, and it is the reverse of today's:

1. read the GitLab issue once;
2. ask `HandoverStop#stop_on_handover` whether a human holds the ticket;
3. **if yes** — no transition, no `restore_working_label`. The row is closed and
   a handover comment is posted, through the existing path
   `ExternalState#close_row!` / `notify_stop` uses, so the sentence and the
   activity row are the ones production already knows;
4. **if no** — the current behaviour, unchanged.

A GitLab read that fails is not a permission: it declines the retry for this
cycle and leaves the row exactly as it was, so the next cycle rediscovers it.
That is the Autodev #67 rule ("a failed read is not a value") and the same choice
#93 made for `UntouchedSinceGiveup`.

**The cost, stated honestly.** The ticket claims this is free because
`manage_labels` already calls `client.issue`. That read happens *inside*
`apply_label_doing` (`lib/autodev/label_manager.rb:166`), i.e. after the
transition — too late to be the one we need. So this is **one extra GitLab read
per errored retry**, not per poll cycle. Against the ~30–45 requests per cycle
Autodev #96 counted, and given how rare an errored retry is, it is negligible;
but it is not zero, and writing "zero" would be exactly the unverified claim this
repository keeps correcting.

`ACTIVE_STATUSES` is **not** widened. It is documented as a boundary in six
places including four tests, and it governs the population of other passes;
changing it to fix one method would widen the blast radius far past the defect.
The decision and its reason go in a comment on `dispatch_unassignment`, so the
next person who wonders finds the answer instead of the question.

## Testing

TDD. Every test verified red against its fix removed.

1. **Two consecutive dispatch cycles with no job execution between them enqueue
   one job.** The central test of #110, and the one that reproduces production.
2. **A losing racer does not enqueue**: the conditional update matching zero rows
   leaves the queue untouched.
3. **The reservation writes both columns**, and `record_recheck_attempt` no
   longer writes either — asserted by running a job and reading the row.
4. **`record_recheck_attempt` refuses to write past the cap**, and warns.
5. **`dispatch_retries`, `dispatch_pipelines` and `dispatch_discussions` are not
   exposed**, and the reason is asserted rather than assumed: a duplicate job for
   each of them is skipped by `DISPATCHED_FROM` after the work has moved the row.
   This is the test that stops the exposure being reintroduced elsewhere without
   anyone noticing.
6. **`next_retry_at` is nil after `perform_retry_errored`**, and after
   `perform_retry_stuck` — one test per path. The absence of both is what let the
   asymmetry settle in.
7. **An errored retry on a ticket taken over by a human does not transition, does
   not restore the working label, closes the row and posts the handover
   comment.**
8. **An errored retry on an untouched ticket behaves exactly as before** — the
   regression guard for section 5.
9. **A GitLab read that raises during the handover check leaves the row
   untouched** and enqueues nothing, with no comment posted.
10. **`HandoverStop` and `PollDispatcher` give the same answer on the same
    input**, since both reach `ExternalState#stop_on_handover` — the guard
    against the wrapper growing logic of its own.

## Docs and i18n

- `fr` and `en` for the handover comment posted on an errored retry, if it needs
  a key of its own rather than reusing the existing stop sentence — reuse first,
  and only add a key if the existing sentence would be false in this context.
- `CLAUDE.md`: the architecture section describes the poll passes and their
  populations. The rule of section 1 belongs there in one sentence, and the
  `error`-outside-`ACTIVE_STATUSES` decision belongs beside it.
- `CHANGELOG.md` `[Unreleased]`, with the 04/09 measurement (five enqueues in
  eighty seconds, `9/5`, the lost watch window).

## Constraints

TDD. RuboCop green on the whole tree. Conventional Commits. `CHANGELOG.md`
`[Unreleased]` in the same pass. i18n `fr` **and** `en` for every visible string.

## Out of scope

- Widening `ACTIVE_STATUSES` — instructed above and deliberately declined.
- Cleaning the production rows that carry a stale `next_retry_at` today.
- The ownership of `needs_clarification` (Autodev #86), which is the same family
  of question — which pass owns which state — on a state this branch does not
  touch.
- Re-selecting powerpanne/core#16030, whose `infra_recheck_count` is 9. Bringing
  it back is a production write and a human decision, not part of this fix.

## Lot alpha 54 — what the other two branches touch

- `fix/109-boot-guard-escalates-to-kill`: `lib/autodev/boot_guard.rb`, a new
  `lib/autodev/process_stopper.rb`, possibly `lib/autodev/supervisor.rb`.
- `fix/105-a-conflicted-mr-is-not-eligible`:
  `app/services/autodev/review_arrears_sweep.rb`.

No code file is shared with either. Expected conflicts in `integration/alpha54`
are positional only: `CHANGELOG.md` `[Unreleased]` and the locale files.

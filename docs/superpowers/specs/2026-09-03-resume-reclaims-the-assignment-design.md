# Putting a request back to work is not complete until autodev holds the ticket again (Autodev #93)

Date: 2026-09-03
Ticket: Skynet Autodev #93 — "Remettre une demande au travail sans reprendre son
assignation : la ligne se fait fermer au cycle suivant, avec un faux
désassignement sur le ticket du client"
Merged in: Autodev #106 (the same mechanism reached from the dashboard's
*Réinitialiser* button, which is the half that was observed in production)

Since Autodev #60 **every** abandon hands the ticket back to a human:
`IssueAbandonment#abandon_issue` calls `hand_ticket_back`
(`lib/autodev/issue_notifier.rb:28`), which reassigns on GitLab. That is
deliberate and right. What is missing is the other half — the gestures that put
such a request back to work do not take the ticket back, so
`dispatch_unassignment` closes the row at the next cycle and posts a sentence
that blames a human for something nobody did.

## Problem

### The two paths, and the comment that hid one of them

**The dashboard's *Réinitialiser*** (`POST /issues/:id/reset` →
`Issue.reset_for_retry!`, `app/models/issue.rb:402`) writes **only** to the
database: the row goes to a working state and `needs_attention` is cleared, and
nothing is written on GitLab. The ticket stays assigned to whoever the abandon
gave it to, and keeps `label_attention`. The `--reset` CLI
(`lib/autodev/dashboard.rb:116`) goes through the same method.

**The infrastructure recheck** re-arms `done` + `stagnation_pipeline` rows
through `PollRouter#resume_recovered_infra` (`lib/autodev/poll_router.rb:77`),
which reposes the working label and does not touch the assignment.

That second path is not an oversight, it is an assertion. The comment on its
sibling (`poll_router.rb:90-93`) reads:

> The caller owns the two things this method deliberately does not: reading
> whether the request is still autodev's, and putting autodev back on the
> ticket. The infra pass gets the first from its own dispatch query and does not
> need the second; the sweep needs both and has different answers.

**"Does not need the second" is false.** The infra pass's population is
`stagnation_pipeline`, and every `stagnation_pipeline` row reached `done` through
`abandon_issue`, which handed its ticket back. The one population that pass
selects is precisely the one whose ticket autodev no longer holds. The sentence
is why that path has no reclaim, and it is why nobody looked.

### What happens next, and what is posted

`dispatch_unassignment` (`app/services/autodev/poll_dispatcher.rb:273`) sweeps
`ACTIVE_STATUSES`, and `ExternalState#stop_unassigned`
(`app/services/autodev/external_state.rb:45`) closes any active row autodev is
not assigned to. On the client's ticket it posts, from
`config/locales/notifications.fr.yml:26`:

> :stop_sign: autodev : j'ai ete desassigne de ce ticket, j'arrete le travail en
> cours.

Nobody unassigned autodev. Autodev handed the ticket back itself when it
abandoned, and then a human asked it to resume. The sentence attributes a
gesture to somebody who did not make it — word for word the harm that opened
Autodev #98.

### Observed in production, 03/09/2026 — powerpanne/core#16030

* 03:11:15 — abandon under `review_failures_exhausted`, GitLab comment, ticket
  handed back to Stephane Meunier (`displaced_assignee_id` 317),
  `Development::StandBy` posted.
* ~10:20 — reset from the dashboard: the row returns to `checking_pipeline`,
  `needs_attention` cleared.
* 10:40:04 — `checking_pipeline` → `closed`, event `unassigned_stop`, comment
  posted.

GitLab state checked immediately after: issue open, assigned to Stephane
Meunier, `Development::StandBy`. Nothing had moved on GitLab between the abandon
and the closure. Twenty minutes of a working state, then a false statement on a
client's ticket.

The infra-recheck path stays **reachable by reading the code and unobserved**:
the thirteen rows that took a recheck exhausted their attempts without the
infrastructure recovering, and re-arming only happens on recovery.

### Scope

Every `needs_attention` request, whatever the reason, since #60 unified the
handback across all give-up paths. Which means: **the *Réinitialiser* button
works today only on requests that were never abandoned** — the `error` ones. On
the requests an operator most wants it for, it does not.

The review-arrears sweep is not a safety net here: `swept_before?`
(`app/services/autodev/review_arrears_sweep.rb:735`) looks for a permanent
origin marker, so a request already swept once is never swept again.

**The exit that does work**, verified on 16030 at 10:54 on 03/09: reassign the
ticket to autodev **and** repose a `labels_todo` label, which triggers Autodev
#52's reentry. It also resets `review_failure_count` to 0, which the reset does
not.

### One instruction of this ticket has become false

The 01/09 version asked that the reassignment "must not overwrite the assignee
list — the union, not the replacement". Autodev #98 established that this is
impossible: our GitLab is Community edition, an issue holds exactly one
assignee, and a union write is accepted (200, no exception) and then silently
ignored. What `ReviewArrearsSweep#reclaim` does is the only thing available, and
it is the model to follow.

## Design

### 1. The reclaim belongs to the passage, not to each caller

Three gestures move a request from a handed-back state into a working state: the
arrears sweep, the infrastructure recheck, and the operator reset. The sweep
carries a reclaim; the other two do not; and the comment quoted above is what
made that look like a decision rather than a gap.

So the reclaim moves into the shared body of that passage. Its callers keep
what is genuinely theirs — the eligibility question, which differs for each
(has the infrastructure recovered; has nobody touched the row since the
give-up; has an operator asked) — and none of them keeps the answer to "does
autodev hold this ticket", because that answer is the same for all three.

The comment on `poll_router.rb:90` is corrected in the same pass. Leaving a
sentence that says a caller does not need this is how the next caller will skip
it too.

### 2. The model is `reclaim`'s, which production has already exercised

`ReviewArrearsSweep#reclaim` (`review_arrears_sweep.rb:447`) ran on eight rows on
02/09 and has the shape this needs:

1. read who holds the ticket, and do nothing if it is already autodev alone;
2. write the assignment;
3. **read it back** — Community accepts and ignores, so an unverified write is
   not a fact (Autodev #98);
4. record the displaced person in `issues.displaced_assignee_id`, so
   `IssueNotifier#handback_target` returns the ticket to them and not to the
   author;
5. announce it in a comment naming the person.

For the reset the announcement can say more than the sweep's, because a human
asked: the comment says autodev is taking the ticket back at an operator's
request, rather than describing a takeover.

### 3. The label

After a reset the ticket still carries `label_attention`; the working label has
to be reposed. Explicitly **without** `clear_scope: true`: that option has one
caller by design (`PollRouter#repose_working_label`, reached only from the
sweep, which has already asked `untouched_since_giveup?`), because clearing the
scope destroys the evidence `LabelHandover` reads. This path must not join it —
the review of the alpha-52 lot settled that, and Autodev #101 is the remaining
structural half.

### 4. The sentence stops claiming a human acted

`unassigned_stop`, both locales. "Autodev n'est plus assigné à ce ticket" is
true and sufficient; "j'ai été désassigné" is not. The sibling
`activity_unassigned_stop` line carries the same claim and gets the same
treatment, and the other messages of that family are checked in the same pass —
`handover_doing_removed` and `handover_done_added` do name a real human gesture
(a resource label event attributes it), so they are correct as they stand.

### 5. Ordering, and what happens when a write fails mid-way

The passage writes to GitLab twice (assignment, label) and to the database once
(the transition). The order is: label first, read the ticket back, then
assignment with its read-back, then the transition — the sweep's order, and for
the sweep's measured reason (`poll_router.rb:98-110`): `manage_labels` answers a
GitLab error with `[]`, so a transient 500 used to leave the row
`checking_pipeline` in the database with its end label still on GitLab, and
`dispatch_unassignment` — which runs *before* `dispatch_pipelines` — read that as
a handover and closed the row blaming a human.

If the assignment cannot be landed, nothing is transitioned and the label is put
back. A half-applied resume is what this ticket is about; it must not be the
remedy's failure mode too.

### 6. Where the GitLab side lives for the reset

`Issue.reset_for_retry!` is a pure database writer with no client, and it is also
called by `revive_stalled!` and `recover_on_startup!` — automatic revivals of
transient states, which have not been handed back and must **not** reclaim
anything. So the GitLab half is a separate collaborator, invoked by the two
operator entry points (`IssuesController#reset` and the `--reset` CLI) and not by
the model method. That split follows the existing `reset_budget:` line: the
parameter already marks an operator-driven reset apart from an automatic one.

Where no GitLab client can be built, the gesture is **refused** with a message
saying why, rather than half-applied — the ticket's point 6, and the same ruling
as §5.

Note for the lot: Autodev #107 also touches `reset_for_retry!`, adding
`review_failure_count` to `reset_budget:`. Different concern, same method;
whichever branch merges second rebases.

## Testing

TDD, and two tests that replay the defect, one per path:

* a row abandoned on pipeline stagnation whose infrastructure recovers;
* a row abandoned on `review_failures_exhausted` and reset from the dashboard.

Neither may be closed at the following cycle, and neither may produce an
`unassigned_stop` comment. 16030's sequence is the fixture for the second.

Also:

* the assignment is **read back**, and a write GitLab accepted and ignored is
  treated as a failure, not a success;
* `displaced_assignee_id` is recorded, and the eventual handback goes to that
  person rather than to the author;
* the announcement names the person;
* the reposed label does not clear autodev's scope;
* a failure of the assignment write leaves the row untransitioned and the label
  as it was;
* `revive_stalled!` and `recover_on_startup!` reclaim nothing — the automatic
  revivals are unchanged;
* a reset with no usable GitLab client is refused and says so;
* `unassigned_stop` no longer asserts that somebody unassigned autodev, in both
  locales.

## Docs

* `CLAUDE.md`: the "One abandon point" decision states the handback; it needs the
  symmetric rule for the resume. The `dispatch_infra_recheck` and reentry
  descriptions need the reclaim.
* The corrected comment on `poll_router.rb:90`.
* `CHANGELOG.md` `[Unreleased]`.
* i18n fr **and** en for every changed and added string, identical `%{var}`
  placeholders.

## Constraints

TDD. RuboCop green over the whole tree. Conventional Commits. `CHANGELOG.md`
`[Unreleased]` updated in the same pass. i18n fr **and** en for every visible
string. Branch `fix/93-resume-reclaims-the-assignment`.

## Out of scope

* **Reading the handover from GitLab's resource label events** instead of the
  current label state — Autodev #101, the structural remedy this ticket's §3
  works around.
* **`error` never being checked for a human takeover** — Autodev #102.
* **Recovering the rows this has already closed.** 16030 was resumed by hand on
  03/09 and is working; there is no arrears population to sweep, and
  `swept_before?` would decline it anyway.

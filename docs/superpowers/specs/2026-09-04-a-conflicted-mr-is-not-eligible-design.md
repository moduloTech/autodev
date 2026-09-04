# A conflicted merge request is not eligible for re-arming (Autodev #105)

Date: 2026-09-04
Ticket: Skynet Autodev #105 — "Le rattrapage des arriérés juge éligible une MR en
conflit : il prend le ticket de quelqu'un pour dépenser jusqu'à une heure et
demie de modèle et abandonner"

`ReviewArrearsSweep#mr_verdict`
(`app/services/autodev/review_arrears_sweep.rb:273`) asks the merge request one
question: its `state`. `opened` answers `:eligible`, full stop. It reads neither
`detailed_merge_status` nor `has_conflicts` — although `describe` (`:779`) reads
and prints both, three lines below, in the very report the operator is looking at
while the sweep decides.

A conflicted merge request is therefore re-armed like any other. The ticket is
**taken** from whoever holds it (GitLab Community: one assignee), with a comment
naming that person and promising to give it back, and the row goes to
`checking_pipeline`.

## Problem

### Measured on 02/09, and the cost is not what the ticket estimated

Of the 6 eligible rows on 02/09 at 17h, **2 were conflicted** — a third:

- 15839, `merge status conflict, conflicts yes`, held by Stephane Meunier
- 14724, `merge status discussions_not_resolved, conflicts yes`, held by Adrien
  RUELLOU

Both were re-armed, because `LIMIT` gives no way to skip them: they were the
first two eligible in examination order, so any `APPLY=1` takes them first.

The ticket predicted roughly ninety minutes of model each, ending in a give-up
under `gitlab_refused_request` (the `400 line_code must be a valid line code`
path bounded by `InvalidRequestBound`, Autodev #95). **That is not what
happened**, and the real outcome is worse and slower. Read from the production
database on 04/09:

| | 15839 | 14724 |
|---|---|---|
| Ran from | 02/09 15:18 | 02/09 15:03 |
| Gave up at | 04/09 01:10 | 04/09 06:02 |
| Elapsed | ~32 h | ~39 h |
| Final `attention_reason` | `stagnation_pipeline` | `stagnation_discussions` |
| `fix_round` | 2 | 7 |
| `discussion_fix_round` | 1 | 6 |
| Reviews launched (`reviewing`) | 2 | 2 |
| Correction rounds (`discussion_fixing`) | 21 | — |
| `discussions_checking` / unchanged | 23 / 4 | 34 / 23 |
| `error` activity events | 19 | 25 |

Neither ended under `gitlab_refused_request`. Both were fully re-armed, ran the
whole correction loop for a day and a half on a merge request that could not
merge, and gave up on stagnation. 15839 alone launched twenty-one danger-claude
correction rounds.

So the ticket's cost model is corrected upward, and the conclusion it pointed to
is reinforced: the expensive outcome is not the fast refusal, it is the full loop
running to its stagnation bound on work that could not land.

### The information was already there

`describe` reads `detailed_merge_status` and `has_conflicts` and prints
`conflicts yes` in the report line — it has done so since the sweep was written.
`conflicts()` (`:785`) even applies the Autodev #67 rule to the field: with
`detailed_merge_status: "checking"`, GitLab has not finished computing, so
`has_conflicts: false` is not a fact and the report says `unknown`.

The decision is the only part that does not look. Declining is therefore free to
implement, which is what makes it the option to take before designing anything
larger.

### Why not rebase first

`rebase_branch_on_target` (`lib/autodev/repo_rebaser.rb:26`) is what the product
uses elsewhere, and on a conflict it goes through `resolve_conflicts_then_continue`
— a danger-claude call, in a working directory. The arrears sweep is a database +
GitLab API pass with no clone and no work_dir. Rebasing from here is a different
pass to design, not a change to `mr_verdict`, and it would put the most expensive
gesture in the product behind a sweep whose whole point is to be cheap enough to
run over a backlog.

## Design

### 1. `mr_verdict` decides on what it already reads

`mr_verdict` gains one question, asked only for `opened` merge requests, on the
two fields `describe` reads:

- `has_conflicts` true → `:mr_conflicted`
- `detailed_merge_status` in the conflict-shaped values (`conflict`) →
  `:mr_conflicted`

`state` keeps its allow-list shape — `MrState.transient?` first, then the
`opened` / `merged` / `closed` case, with anything else `:unknown_state`. The
conflict question is a refinement *inside* `opened`, never a new deny-list.

### 2. An unreadable conflict field is not permission

`detailed_merge_status: "checking"` means GitLab has not finished computing, and
`conflicts()` already refuses to read `has_conflicts` as a fact there. The verdict
follows the same rule: **`:waiting`**, not `:eligible`.

A read that could not answer is not permission to take somebody's ticket — the
Autodev #67 rule, and the same choice #93 made for `UntouchedSinceGiveup`.
`:waiting` costs nothing: the row stays in the arrears, and the next run asks
again, by which time GitLab will have finished computing.

### 3. The verdict is named, counted and reported

`:mr_conflicted` gets:

- an entry in `VERDICTS` (`:126`) so `tally` counts it;
- an entry in `MR_VERDICT_REASON` (`:135`) — the sentence says the merge request
  has conflicts and was left untouched, in the same register as
  `already_merged` and `mr_closed`;
- a column in `report` (`:798`), beside `waiting`, `already merged`, `mr closed`
  and `unknown state`.

Point 3 of the ticket asks for exactly this, and it is the part that matters
beyond the fix: a declined population that is not counted is a population nobody
will ever act on. `attention_reason` is **not** rewritten, for the reason
`mr_closed` already documents — antedating a give-up reason falsifies the record.

These strings are the operator report, which is English throughout this file and
not routed through `Locales`. That stays as it is; adding i18n to one line of a
report whose forty neighbours are English literals would be inconsistency, not
compliance.

### 4. What this deliberately leaves open

A conflicted merge request stays in the arrears indefinitely. Nobody will resolve
the conflict of a merge request autodev gave up on in August, and declining does
not change that.

That is the accepted cost of the option, and section 3 is what makes it
survivable: the population becomes visible in the report instead of being
silently absent, so the next decision — a rebase pass, a human sweep, a bulk
close — is taken on a number rather than on nothing.

## Testing

TDD. Every test verified red against the fix removed.

1. **An `opened` merge request with `has_conflicts: true` is declined**, the row
   is left exactly as it was, and nothing is written to GitLab.
2. **`detailed_merge_status: "conflict"` is declined** even when `has_conflicts`
   is absent from the payload.
3. **`detailed_merge_status: "checking"` answers `:waiting`**, not `:eligible`
   and not `:mr_conflicted` — the row is re-examined on the next run.
4. **A clean `opened` merge request is still eligible and still re-armed** under
   `APPLY=1`: the regression guard, since this change sits on the path of every
   eligible row.
5. **The report counts the declined rows**, and the total across every verdict
   still equals `examined` — the arithmetic check that catches a verdict added to
   the enum and forgotten in the report.
6. **The tally and the reason table stay in step**: a verdict present in
   `VERDICTS` and absent from `MR_VERDICT_REASON` must fail a test rather than
   raise `KeyError` in front of an operator, since `consider` (`:260`) fetches
   from it.

## Docs

- `CHANGELOG.md` `[Unreleased]`, carrying the measured outcome of 15839 and
  14724 — 32 and 39 hours, 21 correction rounds, two give-ups on stagnation —
  because it corrects the estimate written in the ticket and in the error
  catalogue.
- The error catalogue's costing of `gitlab_refused_request` mentions the
  conflicted-MR path as its scenario. It should say that the measured path was
  the stagnation bound instead, so the next reader is not costed against a case
  that did not occur.

## Constraints

TDD. RuboCop green on the whole tree. Conventional Commits. `CHANGELOG.md`
`[Unreleased]` in the same pass. i18n `fr` **and** `en` for any string that is
routed through `Locales` — see section 3 for why the report lines are not.

## Out of scope

- Rebasing before deciding. Instructed above and declined, with its reason.
- Any change to `LIMIT` or to the examination order.
- What to do with the arrears population that will now accumulate declines. That
  is the decision section 4 leaves open on purpose, and it needs the number this
  change produces before it can be taken.
- 15839 and 14724 themselves. Both have already given up on their own; nothing
  here re-arms or cleans them.

## Lot alpha 54 — what the other two branches touch

- `fix/109-boot-guard-escalates-to-kill`: `lib/autodev/boot_guard.rb`, a new
  `lib/autodev/process_stopper.rb`, possibly `lib/autodev/supervisor.rb`.
- `fix/110-111-102-the-pass-writes-what-it-selects-on`:
  `app/services/autodev/poll_dispatcher.rb`, `app/jobs/issue_process_job.rb`,
  `lib/autodev/pipeline_monitor/infra_recheck.rb`, a new
  `app/services/autodev/handover_check.rb`.

No code file is shared with either. Expected conflicts in `integration/alpha54`
are positional only: `CHANGELOG.md` `[Unreleased]` and the locale files.

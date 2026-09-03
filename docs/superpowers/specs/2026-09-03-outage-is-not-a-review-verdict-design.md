# A review that could not be produced is not a verdict on the merge request (Autodev #107)

Date: 2026-09-03
Ticket: Skynet Autodev #107 — "Une panne d'infra dépense le budget de review :
cinq échecs consécutifs comptés sans qu'aucune revue ait pu démarrer, et la
demande abandonnée pour ça"

**The ticket asks to separate two things, and only one of them exists.** It asks
to tell "the review ran and failed — a verdict on the merge request" from "the
review could not run". There is no verdict side: on neither path can a review
failure mean the merge request was judged and found wanting. So the line to draw
is a different one, and it is drawn below.

Depends on Autodev #108, which is what makes `claude_available?` answer false on
a broken tool — that closes most of the occasions this ticket is about, ahead of
the reviewer. It does not close the defect.

## Problem

### There is no such thing as a review that failed on its merits

On the **skill path**, `publish_from_contract`
(`lib/autodev/pipeline_monitor/skill_reviewer.rb:153`) returns `true`,
`:inconclusive` or `:unanchored`. It never returns `false`. A review that judges
the merge request unfavourably is a `changes_requested` verdict, and that
travels as `true` (published) or `:unanchored` (published but holding nothing).

The only `false` on that path comes from one rescue
(`skill_reviewer.rb:40`) covering exactly three things:

1. **the clone did not complete** — and it arrives there deliberately:
   `clone_for_review` (`:96`) re-wraps every `StandardError` into
   `ImplementationError` precisely so a clone failure "counts as a review
   failure" (its own comment, Autodev #74 fix round 1), because `GitError` is a
   sibling of `ImplementationError` and would otherwise escape;
2. **`danger_claude_prompt` raised** — the tool could not run: the container
   runtime, a timeout, a crash;
3. **the contract file is absent or off-schema** (`ReviewContract::InvalidError`).

On the **binary path**, `execute_mr_review` (`reviewer.rb:252`) rescues
`StandardError` into `false`: `mr-review` absent, a timeout, a crash, a non-zero
exit.

None of the four is a statement about the merge request. `review_failure_count`
is, in its entirety, a counter of **reviews that could not be produced** — and
the constant says so itself (`reviewer.rb:17`): "without a cap the
checking_pipeline ↔ reviewing loop runs forever on a persistently broken
mr-review (token expired, binary crash, etc.)". The budget was built to bound a
broken tool.

Taken literally, then, the ticket's instruction would empty the counter of all
content and leave nothing behind it.

### The line that does exist

Not verdict against outage, but **a cause specific to this request** against **a
cause shared by every request**. A deleted source branch fails this request's
clone forever and no other; a dead container runtime fails all of them. The
first deserves a per-request give-up. The second deserves a health card, and
Autodev #108 has just added one.

### What it cost, measured

The Docker engine on bobette was broken from 02/09 23:00 UTC to 03/09 08:26.
Every `danger-claude` invocation failed in `ensure_volume`, before any container
started, on an API-version mismatch. 68 failed calls, 7 to 10 an hour, without
interruption.

powerpanne/core#16030 crossed that window. It had been re-armed the day before
by the review-arrears sweep, which **took its ticket** from Stephane Meunier
with a comment naming him and promising it back. Its five review failures were
all counted inside the outage, each about two minutes apart — the time to find
that the container would not start. At 03:11 it was abandoned under
`review_failures_exhausted`, with a GitLab comment announcing that "the review
failed 5 consecutive times", `Development::StandBy` posted, and the ticket handed
back.

Its merge request was `mergeable, conflicts no`. Nothing was wrong with it. It
was abandoned because Docker was broken, and the promise made to a named person
was not kept.

### The reset gesture leaves no margin, and says nothing

`review_failure_count` is cleared only by a successful review
(`reset_review_failure_count`, from `finalize_review_success`) and by the two
reentry paths in `resume_handler.rb` (`:127` and `:157`). `Issue.reset_for_retry!`
(`app/models/issue.rb:402`) does not touch it. After the reset, 16030 still
carried 5 on a threshold of 5, so the very next failure would have abandoned it
immediately. The operator who clicks has no way to know that.

And the method already has the parameter this belongs under. `reset_budget:`
zeroes `retry_count` and its comment says why — "for an operator-driven reset,
which means *clean slate*". `review_failure_count` is a budget; it was simply
never added to that list.

### The bound, checked rather than assumed

Routing these failures back to the watch is only safe if something still bounds
them. It does: `poll_inconclusive!` — the flag that stands the age bound down —
is raised in exactly three places, the two quota deferrals
(`lib/autodev/pipeline_monitor.rb:208` and `:214`) and the pipeline evaluation
(`pipeline_monitor/evaluator.rb:41`). No review outcome raises it, and
`:inconclusive` deliberately does not (Autodev #74). So a review that returns to
the watch is still given up at `pipeline_watch_max_days` under
`pipeline_watch_expired`, which hands the ticket back to a human.

## Design

### 1. The outcomes are named where they are produced

`dispatch_review_outcome` already dispatches on symbols, so this is the shape the
code is in rather than a new one. The two rescues stop collapsing into `false`
and answer with a named outcome:

| outcome | produced by |
|---|---|
| `:tool_unavailable` | `danger_claude_prompt` raised; `mr-review` absent; either binary timed out; `mr-review` exited non-zero |
| `:clone_failed` | the clone did not complete |
| `:unusable_output` | the contract file is absent or off-schema |

`false` disappears from both paths' vocabulary. Which cause a
`danger_claude_prompt` failure is gets classified by the shared classifier
Autodev #108 introduces, so "the tool could not run" has one definition in the
product rather than two.

`mr-review` exiting non-zero is `:tool_unavailable` and not `:unusable_output`:
the binary posts to GitLab itself, so its exit status carries no verdict we can
read, and we cannot tell a crash from a refusal. Which means the binary path no
longer spends the budget at all — the honest outcome, given that its credential
was revoked for four months (Autodev #80) while this counter was the only thing
watching and never said so.

### 2. What each outcome does

* `:unusable_output` → `finalize_review_failure`, unchanged: it spends the
  budget and keeps `review_failures_exhausted`. It is the one cause that is about
  *this* merge request meeting *this* skill, and it recurs identically on every
  poll, so a per-request bound is the right instrument.
* `:tool_unavailable` and `:clone_failed` → `resume_watch`: neither counter
  moves, the watch clock is restored, and the next poll runs the whole review
  again. Exactly `:inconclusive`'s mechanism, for exactly its reason (Autodev
  #74, #71 — an outage must not spend a budget).

### 3. Why the clone sits on the non-spending side

A clone failure *can* be request-specific — a deleted source branch — and the
existing comment on `clone_for_review` chose to count it for that reason. That
choice is reversed here, and the argument is the failure direction rather than
the taxonomy.

A clone failure cannot be attributed without evidence nobody gathers: Autodev #96
measured roughly 9% of GitLab reads failing from bobette by TCP refusal, in
bursts, on tickets that changed from one pass to the next. So the same
`ImplementationError` covers "this branch is gone" and "the network hiccuped".

Over-spending the budget abandons a healthy request and posts a false statement
on a client's ticket — measured, on 16030, with a named person's promise broken.
Under-spending costs polls whose clone fails fast, bounded at
`pipeline_watch_max_days`. The asymmetry is not close.

Positively identifying a deleted source branch — the `MissingTargetBranchError#confirmed?`
idiom (Autodev #91) applied to the source rather than the target — is the natural
follow-up and is out of scope here.

### 4. The activity trail distinguishes them

A review failure writes `:review_failed` with its count. A non-spending outcome
cannot write that: the count did not move, and a line claiming otherwise is the
defect this lot exists to end. So each outcome gets its own activity key, and an
operator reading the timeline can tell "the tool could not run" from "the
review's output was unusable" without opening a log.

No GitLab comment on the non-spending outcomes. Nothing is being asked of
anyone, and `:inconclusive` already sets that precedent — a note appended on
every poll through a nine-hour outage is the growth Autodev #53 went to some
trouble to bound.

### 5. `review_failure_count` joins `reset_budget:`

One line: `fields[:review_failure_count] = 0 if reset_budget`. No new parameter
and no new decision — `reset_budget:` already means "clean slate", and this
counter is a budget.

That also settles which callers are affected, correctly and without a second
thought: the two operator-driven resets pass it (`IssuesController#reset`,
`app/controllers/issues_controller.rb:65`, and the `--reset` CLI through
`lib/autodev/dashboard.rb:116`), while `revive_stalled!` and
`recover_on_startup!` do not — an automatic revival has no business clearing a
budget, which is the distinction the parameter exists to draw.

`reset_for_retry!` is also modified by Autodev #93 in this lot, which makes the
reset write to GitLab. Different concern, same method: whichever branch merges
second rebases. Neither change depends on the other.

### 6. What Autodev #108 already removes, and what is left

After #108, `handle_green` (`pipeline_monitor.rb:166`) returns
`defer_review_for_usage` before the review is attempted whenever `available?` is
false, which now includes a broken tool. So a first review is no longer
attempted during a tool outage at all, and 16030's exact sequence cannot recur.

What is left for this ticket, and why it is still worth doing:

* a fault that starts *after* the cycle's probe and before the review — 16030
  burned its five failures in ten minutes;
* clone failures, which the gate does not cover and which #96 measured as
  routine;
* the reset gesture, which is independent of any outage;
* and the property itself: the counter should not be able to give a request up
  for a cause that is not about the request, whatever else happens to prevent it.

### 7. Where the code goes

* `lib/autodev/pipeline_monitor/skill_reviewer.rb` — named outcomes in place of `false`.
* `lib/autodev/pipeline_monitor/reviewer.rb` — `dispatch_review_outcome`, and the binary path's rescue.
* `app/models/issue.rb` — `review_failure_count` joins `reset_budget:`.
* `config/locales/activity.{fr,en}.yml` — the new activity keys.

## Testing

TDD, and the regression is written first: **a request whose `danger-claude` call
cannot run does not lose a review budget, and is not abandoned**, with the Docker
500 as the fixture.

* One test per outcome, asserting the pair that follows: whether
  `review_failure_count` moved, and which state the row is in.
* `:tool_unavailable` five times in a row leaves `review_failure_count` at 0 and
  the row in `checking_pipeline`.
* `:unusable_output` five times in a row still abandons under
  `review_failures_exhausted` — the bound that remains must remain.
* A clone failure spends nothing, whatever its cause.
* `resume_watch` on these outcomes does not restamp `checking_pipeline_since`
  (Autodev #74's lesson), so the age bound still fires on schedule; and it does
  not raise `poll_inconclusive!`, so the bound is not stood down.
* The age bound does give such a row up at `pipeline_watch_max_days`, under
  `pipeline_watch_expired` — the test that proves the replacement bound is real.
* `reset_for_retry!(reset_budget: true)` clears `review_failure_count`, and
  `reset_for_retry!` without it does not — the automatic revivals keep their
  budget.
* No GitLab comment is posted on a non-spending outcome.

## Docs

* `CLAUDE.md`'s error catalogue carries several rows on the review path stating
  that a failure is counted; they need the split. The `PipelineMonitor` section's
  review bullet too.
* `CHANGELOG.md` `[Unreleased]`.
* i18n fr **and** en for the new activity keys, with identical `%{var}`
  placeholders.

## Constraints

TDD. RuboCop green over the whole tree. Conventional Commits. `CHANGELOG.md`
`[Unreleased]` updated in the same pass. i18n fr **and** en for every visible
string. Branch `fix/107-outage-is-not-a-review-verdict`.

## Out of scope

* **Recovering powerpanne/core#16030.** It is closed with its ticket at
  Stephane Meunier and cannot come back through the arrears sweep, whose
  `swept_before?` marker is permanent. An operational gesture on production, not
  code, and it needs a decision about the promise made to him.
* **Positively identifying a deleted source branch**, which would move
  `:clone_failed` onto the spending side for that one cause.
* **`MAX_REVIEW_ROUNDS` being dead code.** That is Autodev #78, outside this lot.
* **The fleet-level signal.** `HealthReport#check_mr_review` (Autodev #60) and
  the new `danger_claude` card (Autodev #108) are where "the tool is broken for
  everybody" is said. This ticket only stops individual requests from being
  sacrificed to say it.

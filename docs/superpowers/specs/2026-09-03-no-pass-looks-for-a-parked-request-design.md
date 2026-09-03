# An `error` row nothing selects, and a stamp nobody decides (Autodev #103)

Date: 2026-09-03
Ticket: Skynet Autodev #103 — "Un 401 gare la demande là où plus aucune passe ne
va la chercher : réparer les identifiants ne la ramène pas, et rien ne dit
lesquelles attendent"

**The 401 is one entrance to the problem, and not the widest.** Two of the three
generic error handlers never stamp `next_retry_at` either, so *any* error on the
pipeline or MR-fix trees parks its row in the same place. And the defect has a
mirror image the ticket found without naming: a stamp that survives a
re-entry makes a row retryable for ever, with no backoff. Both come from the
same absence — nothing decides what `next_retry_at` should be when a row enters
`error`.

## Problem

### The two exits, and what each one requires

A row in `error` leaves by one of exactly two doors:

* `PollDispatcher#fetch_retryable` (`app/services/autodev/poll_dispatcher.rb:381`)
  requires `retry_count <= max_retries` **and**
  `next_retry_at IS NOT NULL AND next_retry_at <= now`;
* `DormantAudit#error_arm` (`app/services/autodev/dormant_audit.rb:109`)
  requires `retry_count > max_retries`.

A row with no stamp and an unspent budget satisfies neither. `max_retries`
defaults to 1, so a request that errors on its first attempt sits at
`retry_count` 0 or 1 — in no population at all. Its only way out is a human
pressing *Réinitialiser*.

### Who writes `error` without a stamp — it is not just the 401

| handler | stamps `next_retry_at`? |
|---|---|
| `PipelineMonitor::ErrorHandler#handle_rate_limit` (`:8`) | yes, at the reset time |
| `MrFixer::ErrorHandler#handle_rate_limit` (`:8`) | yes |
| `IssueProcessor::ErrorHandler#handle_rate_limit` (`:8`) | yes |
| `IssueProcessor::ErrorHandler#handle_process_error` (`:34`) | yes, with backoff, **while** `retry_count <= max` |
| `PipelineMonitor::ErrorHandler#handle_auth_failure` (`:21`) | **no** |
| `MrFixer::ErrorHandler#handle_auth_failure` (`:22`) | **no** |
| `IssueProcessor::ErrorHandler#handle_auth_failure` (`:24`) | **no** |
| `PipelineMonitor::ErrorHandler#handle_failure_error` (`:43`) | **no** |
| `MrFixer::ErrorHandler#handle_fix_error` (`:32`) | **no** |

The three `handle_auth_failure` are deliberate and right: retrying against dead
credentials cannot produce anything. The last two are not a decision at all.
They mark the row `error`, write a message, post a comment and stop — so a
pipeline-evaluation error or an MR-fix error gets **zero** retries, while the
same class of error during initial processing gets `max_retries` with backoff.
That asymmetry is not written down anywhere, and it is the widest entrance to
the parked population.

### Measured over the product's life

Business `transition` rows are never deleted (Autodev #57), so the whole history
is on file. Pairing every transition **into** `error` with the next transition of
the same row:

* **307 entries into `error`**, 304 with a measurable exit;
* median stay **13 666 s — 3 h 48**, which is the healthy shape: a stamp plus
  `retry_backoff`;
* **51 stays over 24 h**, **21 over 7 days**, and one of **79 days**.

And the frequency of the unstamped paths, from the activity trail:

* `error` (the two generic handlers plus `handle_process_error`): **221 events
  across 42 distinct requests**, 14/05 to 03/09;
* `auth_failure`: **17 events across 11 requests**, 29/07 to 02/09;
* `rate_limit`, which does stamp: 147 events across 48 requests.

The three rows of 02/09 the ticket describes are the instance somebody watched.
The 21 stays over a week are the population.

### The mirror defect: a stamp nobody clears

15888 came back on its own after the credentials were fixed, and the ticket is
right that this was luck. Its `next_retry_at` was **2026-05-14** — a residue from
an error in May that survived every transition since, because no handler on the
`error` path writes that column unless it has a reason to.

An expired stamp does not mean "retry once". It means `next_retry_at <= now` is
true for ever, so the row is selected on **every** cycle with no backoff at all.
The parked row costs nothing and goes nowhere; this one is picked up
indefinitely. Two failure directions, one cause: entering `error` does not
decide what the stamp should be.

### They are listed — they are just not distinguishable

The ticket says nothing tells you which requests are waiting. Half right, and
the half that is wrong changes the remedy.

`/errors` no longer exists — its concerns became the `/issues` tabs, and
`Web::IssuesFilter` (`app/helpers/web/issues_filter.rb:28`) selects
`status: 'error'` for the errors tab. So a parked row **is** on the screen. What
the screen cannot say is that no pass will ever pick it up: it sits next to rows
that will retry themselves in four minutes, rendered identically. (`CLAUDE.md`
still documents the removed `ErrorsController`, which is how the ticket came to
believe the rows were invisible.)

So the remedy is not a list. It is a distinction.

## Design

### 1. `DormantAudit`'s error arm becomes the complement of `fetch_retryable`

The two predicates describe one question — "will a pass pick this row up?" — and
today each answers it separately, which is how a gap opened between them. The
arm is therefore **derived** rather than restated: an `error` row is dormant when
`fetch_retryable` would not select it and never will, which is

```
next_retry_at IS NULL  OR  retry_count > max_retries
```

A row with a *future* stamp is excluded: it is waiting, not dormant. That is the
whole change to the population, and it is the shape Autodev #47 already
established for the stuck-issues card and this pass — one definition, so the
screen cannot flag what nothing recovers.

The arm also gains the activity-age guard its two siblings have
(`without_activity_since(poll_stale_after)`). `pending_arm` carries one for a
stated reason — a freshly discovered row has a NULL stamp for a moment — and
the same applies here: a row that has just errored must not be audited inside
the same cycle that wrote it.

### 2. What the audit then does, which is already what is wanted

`DormantAudit#revive` (`:209`) sets `retry_count: 0, next_retry_at: Time.current`
on a non-stalled row, so a revived `error` row becomes retryable at the next
cycle. Before that it asks GitLab the three questions the pass exists for —
closed, unassigned, handed over by label — and closes the row instead of
reviving it when the answer is one of those.

It is bounded by construction: `dormant_audit_max` (default 3) attempts spaced by
`dormant_audit_backoff` (default 3600 s), after which the row is flagged
`needs_attention: dormant_exhausted` and a human is told. That is exactly the
ticket's option (a), and it is why option (b) — re-stamping when an
authentication probe goes green — is not needed: a periodic bounded audit
recovers the 401 population without an action at a distance, and it recovers the
other 42 requests too, which (b) never could.

Re-arming a 401 row costs nothing it should not: after Autodev #108
`UsageGate.available?` answers false on `auth_refused`, so the passes that reach
`danger-claude` are skipped and the revived row waits without spending a call.

### 3. The stamp becomes a decision, made in one place

`safe_mark_failed!` (`lib/autodev/danger_claude_runner.rb:179`) is the single
funnel every `error` entry goes through. It takes the decision explicitly:

* a caller scheduling a retry passes the moment;
* a caller that deliberately schedules none — the three `handle_auth_failure` —
  says so, and the column is **cleared**.

Clearing is the half that fixes 15888: a residue from May is not a schedule, and
leaving it turns "no retry" into "retry on every cycle for ever". Making the
argument mandatory is what keeps a *new* handler from joining the parked
population by omission — the failure mode that produced this ticket.

The two generic handlers keep scheduling no retry, so their rows are cleared and
recovered by the audit. Whether they *should* retry — the asymmetry with
`handle_process_error` — is a policy question this measurement raises and does
not answer; see Out of scope.

### 4. The errors tab distinguishes waiting from stranded

One derived predicate on the row, reading the same rule as §1, and the errors tab
marks the rows no pass will pick up. Nothing new is queried: `next_retry_at` and
`retry_count` are already on the row the tab renders.

Rendered as a distinct state rather than as a count, because the operator's
question is per row — "must I do something about this one?" — and the answer is
either "it comes back by itself at 14:02" or "it is waiting for you". The `401`
card the dashboard already carries says the credentials are dead; it does not and
should not say which requests that stranded.

### 5. Where the code goes

* `app/services/autodev/dormant_audit.rb` — the derived arm and its age guard.
* `app/services/autodev/poll_dispatcher.rb` — `fetch_retryable`'s predicate named
  once so the arm can be its complement.
* `lib/autodev/danger_claude_runner.rb` — `safe_mark_failed!` takes the stamp decision.
* `lib/autodev/{pipeline_monitor,mr_fixer,issue_processor}/error_handler.rb` — each caller states it.
* `app/helpers/web/issues_filter.rb` + the issues view — the distinction.
* `config/locales/web.{fr,en}.yml` — the label for it.

## Testing

TDD, and the regression first: **a row in `error` with no stamp and an unspent
budget is recovered without a human**, which no test asserts today.

* The derived arm: a row `fetch_retryable` would not select is in the audit's
  population, and one it would select is not — asserted against the two
  predicates rather than against hand-written column values, so they cannot
  drift apart again.
* A row with a *future* stamp is neither retryable now nor dormant.
* A 401 row: no stamp on entry, picked up by the audit after the age guard,
  revived, and — over `dormant_audit_max` fruitless rounds — flagged
  `dormant_exhausted`.
* An `error` row carrying an expired stamp from a previous life is **not**
  selected every cycle: entering `error` with no retry scheduled clears it.
  15888's `2026-05-14` is the fixture.
* `safe_mark_failed!` cannot be called without deciding the stamp — the guard
  that keeps a new handler from repeating this.
* A row that has just errored is not audited inside the same cycle.
* The errors tab marks the stranded rows and not the waiting ones.

## Docs

* `CLAUDE.md`: the error catalogue's "Row dormant" line lists three arms and
  needs the widened one; the Web UI section still documents `GET /errors` →
  `ErrorsController#index`, which no longer exists — corrected in the same pass,
  since believing it is what made this ticket's second half wrong.
* `CHANGELOG.md` `[Unreleased]`.
* i18n fr **and** en for the new label, identical `%{var}` placeholders.

## Constraints

TDD. RuboCop green over the whole tree. Conventional Commits. `CHANGELOG.md`
`[Unreleased]` updated in the same pass. i18n fr **and** en for every visible
string. Branch `fix/103-no-pass-looks-for-a-parked-request`.

## Out of scope

* **Whether the two generic handlers should retry at all.** A pipeline-evaluation
  or MR-fix error gets zero retries while the same error during initial
  processing gets `max_retries` with backoff. The measurement says the asymmetry
  is real and undocumented; deciding it is a policy question, and the audit makes
  it safe to defer.
* **An authentication probe driving the recovery** (the ticket's option b). The
  audit covers the population without it. Autodev #108 adds the probe for the
  *signal*, which is what was actually missing.
* **Backfilling the 21 requests that stayed over a week.** They have all since
  left `error`; there is no arrears population to sweep.

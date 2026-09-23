# `needs_clarification` has an owner (Autodev #86)

## Problem

A request parked in `needs_clarification` has exactly one reader: `dispatch_new_issues`
→ `PollRouter#route_by_state` → `PollDispatcher#process_issue` → `clarification_received?`
(Autodev #75). That reader only sees the rows GitLab returns for "assigned to autodev **and**
carrying a `labels_todo` label", and it only *resumes* — it never signals. No other pass selects
the state: it is in neither `PollDispatcher::ACTIVE_STATUSES` (`dispatch_unassignment`) nor
`Issue::STALLED_STATES` (`DormantAudit#active_arm`).

Three cases therefore have no owner, and the ticket asks that they be treated as one question:

1. **Reassigned to a human** (or its entry label moved): the row leaves `dispatch_new_issues`'
   population and nothing reads it again. `ClarificationSweep#still_ours?` reports it and
   deliberately abstains.
2. **Budget spent**: `process_issue` refuses the row before `skip_existing?` (correct — it must not
   consume the answer) and logs `log_budget_spent`. Nothing reaches a human.
3. **No age bound**: an unanswered question waits forever, unlike a pipeline watch
   (`pipeline_watch_max_days`, Autodev #53).

## Measurements (production, read-only, 23/09/2026)

- `issues` by status: 62 `closed`, 85 `done`, 1 `implementing`, **0** `needs_clarification`.
- 18 entries into `needs_clarification` on record since 12/05/2026. Since #75 shipped (28/08), one
  (row 157, answered 2 h 27 min later through the nominal path).
- Row 68 (powerpanne/core #14856) sat in case 1 for 131 days (asked 15/05/2026, answered
  16/05/2026, reassigned to a human 11/06/2026). It was re-armed this morning by reassigning the
  ticket to autodev: `clarification_received` at 05:26:04 UTC, now `implementing`.
- The web UI already *shows* these rows (tab `waiting`, KPI `awaiting`), always as "Waiting on your
  input". What is missing is a truthful signal, not visibility.

## Decisions (owner, 23/09/2026)

| Case | Decision |
|---|---|
| Reassigned to a human / entry label gone | **Flag and keep**: `needs_attention`, row stays `needs_clarification` |
| Unanswered past a bound | **Flag after `clarification_max_days`** (default 14, `0` = off), row keeps waiting |
| Budget spent | **Flag** (follows from the two above) |
| GitLab comment on any flag | **None** — operator signal only, like `dormant_exhausted` |
| Ticket closed on GitLab | `closed`, as `dispatch_unassignment` does for active rows (assumption stated to the owner, not contested) |

### Why "keep", not "close", for a reassigned row

Closing is what `dispatch_unassignment` does for an active row, and it would break the one gesture
that works today. Re-entry from `closed` requires a `labels_todo` label **applied after**
`finished_at` (`LabelHandover#todo_reapplied_after?`, Autodev #52). A parked request already
carries that label — `SpecChecker#post_clarification` reposed it when the question was asked — so
the documented "reassign me" loop would be a silent no-op: no new label event, the row stays
`closed`. Row 68 is the counter-example: it resumed this morning *because* nothing had closed it.

### Why a dedicated pass, not the dormant audit

`DormantAudit` has two outcomes — close or revive — and "revive" means nothing for a row that is
waiting on a human rather than stalled. Its cap (`dormant_audit_max`, 3, one hour apart) would stop
looking after three hours, and its clock is `Issue.without_activity_since`, which a waiting row
has no reason to feed. Adding the state to `STALLED_STATES` would also reach boot recovery
(`recover_on_startup!`), which would move every parked row to `pending` at each restart.

### Does the #75 arbitrage change the answer?

Yes, and it is what makes the pass cheap. Because the entry label is reposed while waiting, a
healthy parked row **is** in `dispatch_new_issues`' GitLab result every cycle. A row absent from
that result is exactly a row that left the population — reassigned, relabelled, or closed. So the
pass reads GitLab only for rows that were *not* in the list the cycle already fetched.

## Design

### `Autodev::ClarificationWatch` (new, `app/services/autodev/clarification_watch.rb`)

Built per project per cycle by `PollDispatcher#dispatch_existing`, after `dispatch_unassignment`.
Input: the set of issue iids `dispatch_new_issues` received from GitLab this cycle (`seen_iids`),
or `nil` when that pass did not run (Claude gate closed) — then the GitLab arm is skipped and only
the database arms run.

Population: `Issue.where(project_path:, status: 'needs_clarification')`, read **after**
`dispatch_new_issues`, so a row resumed this cycle is already `pending` and out of it.

Per row, in this order:

1. **Reach arm** — only when `seen_iids` is not nil.
   - Row in `seen_iids` → it is reachable. If it carries a reach flag
     (`clarification_reassigned` / `clarification_label_moved`), clear it.
   - Row not in `seen_iids` and not already carrying a reach flag → one `@client.issue` read:
     - closed on GitLab → `close_externally` (`ExternalState`, the existing closure).
     - not assigned to autodev → flag `clarification_reassigned`.
     - assigned, no `labels_todo` label → flag `clarification_label_moved`. The explanation does not
       claim a human did it: `repose_entry_label` swallows its own failure, so autodev can be the
       cause.
     - assigned and carrying a todo label → nothing (the row parked after the list was fetched).
   - A failed read (`Gitlab::Error::ResponseError`, `ApiUnavailableError`) declines the row for the
     cycle. It never reads as a verdict (Autodev #62).
2. **Budget arm** — `retry_count > Config.max_retries` → flag `clarification_budget_spent`.
3. **Age arm** — `clarification_max_days > 0` and `clarification_requested_at` older than that →
   flag `clarification_unanswered`. A NULL `clarification_requested_at` is not aged (it already
   reads as answered, `ClarificationResume#answered?`).

A row carries **one** `attention_reason`. Ranking, strongest first: `clarification_reassigned`,
`clarification_label_moved`, `clarification_budget_spent`, `clarification_unanswered`. A flag
overwrites a weaker one, never a stronger one, and is written only when it changes the row — so
the pass writes nothing on a cycle where nothing changed.

A flag write is a compare-and-set that repeats `status = 'needs_clarification'`, plus one
`ActivityLogger.warn_event` (database only, no GitLab note) and one log line.

### Cost

- Nominal: **zero** GitLab calls. A healthy row is in `seen_iids`.
- A row leaving the population: **one** `client.issue` read, then none once flagged. A read that
  failed is retried next cycle.
- Accepted limit: a row flagged `clarification_reassigned` whose ticket is later closed on GitLab
  stays flagged in `needs_clarification`. It is on the operator's board, and the dashboard close
  button ends it. Re-reading flagged rows every cycle would cost 288 reads per row per day for
  that.

### Clearing

- `ClarificationResume#resume!` clears the `needs_attention` trio. A resumed request restarts, and
  every flag this pass sets is about the wait that just ended.
- The reach arm clears a reach flag when the row is back in `seen_iids`. Budget and age flags are
  cleared only by a resume or an operator reset.

### Dormant-audit trap (Autodev #74 / #81)

Not reachable: `needs_clarification` is in none of `DormantAudit`'s arms, and the pass writes an
activity row only when a flag changes, never per cycle. The age clock is
`clarification_requested_at`, not activity.

### Setting

`clarification_max_days`: `NumericSettings::SPECS` `[0, 365]` (the `pipeline_watch_max_days`
range, `0` = bound off), `Config::DEFAULTS` 14, read per project → global → default.

### Rendering

`WatchCards#explain_key`: a `needs_clarification` row **with** `needs_attention` explains its
attention reason (`web_errors_explain_attention_<reason>`). Without the flag it keeps
`web_errors_explain_clarification`. The cause headline stays `web_errors_cause_clarification`.

### i18n

For each of the four reasons: `activity_<reason>` (activity.fr/en) and
`web_errors_explain_attention_<reason>` (web.fr/en). No bare notification key: declared in
`test/i18n_derived_keys_test.rb`'s `NO_GITLAB_COMMENT`, as `dormant_exhausted` is.

## Out of scope

- A reminder comment to the requester (owner: no GitLab write).
- `ClarificationSweep`'s behaviour (one-shot arrears); only its comment, which says no pass sweeps
  the state, changes.
- The status pill's label ("Waiting on your input"); the explanation line carries the truth.

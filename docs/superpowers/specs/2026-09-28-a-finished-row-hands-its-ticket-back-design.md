# A finished row hands its ticket back (Autodev #126)

## Problem

A request autodev no longer follows (`done` or `closed`) can leave its GitLab ticket assigned to
the autodev bot. Nobody sees it: the bot's own list is nobody's list, and autodev does not read it.

## Measurements (28/09/2026, production read-only)

Population — open tickets assigned to the bot (`group_181_bot_…`) joined with the autodev row:
**20** on powerpanne/core, **0** on ff/fast/core. Of the 20, **8** carry a terminal row:

| Row | Ticket | Row status | How it got there |
|---|---|---|---|
| A#43, A#89, A#124 | PP#10869, 15971, 16075 | `done`, `stagnation_pipeline` | Abandoned 03–09/07, before the #98 handback existed. Extinct cause, stock |
| A#130, A#132 | PP#16258, 16237 | `closed` | **Not the Clore button** (the ticket's reading). `audit_logs` records `issue.transition_auto` from `checking_pipeline` on 11/08 14:00, and the activity entry is `handover_workflow_moved` (`Development::Awaiting CR`): `ExternalState#stop_on_handover` closed the row and left the ticket on the bot. 5 handover stops on record |
| A#82 | PP#15676 | `closed` | `issue.transition_manual`, `done → closed`, 24/09 — the Clore button. Not in the ticket |
| A#134 | PP#16354 | `done` | See below |
| A#50 | PP#15157 | `done` | `finished_at` is the literal text `datetime('now')` |

The other 12 are active rows (`fixing_discussions`, `error`, `checking_pipeline`, mostly flagged
`dormant_exhausted`) and one ticket with no row (PP#16190). They are not this change's population.

**A#134, measured.** `transition checking_pipeline → done (pipeline_green)` at 10:18:06 UTC on
04/09. The production log (`production.log.20260906-063000`, local time 12:18) shows
`Pipeline check failed for issue #16354: Net::OpenTimeout: Failed to open TCP connection to
source.modulotech.fr:443` eight seconds later. No `pipeline_green_done` activity follows, and
`finished_at` still holds the `mr_created` time (06:15:43). `finalize_green_done` calls
`apply_label_done` → `manage_labels` → `@client.issue` first; `manage_labels`, `hand_ticket_back`
and `notify_issue` rescue `Gitlab::Error::ResponseError` only, and `Net::OpenTimeout` is a
`Timeout::Error`. The exception escaped to `PipelineMonitor#check`, which only logs. The row stayed
`done`, unflagged, with the ticket on the bot and on `Development::Doing`.

**A#50, measured.** Three rows carry the literal: A#27, A#50, A#62, all created 07–16/04/2026.
`8719046` (30/03) fixed Sequel's `model#update` escaping `Sequel.lit("datetime('now')")` in
`IssueProcessor` only; Sequel is gone since `6666b8d` (08/06). No code path can write it any more.
Repaired in production data, not in code.

## Decisions

1. **The three GitLab write helpers never raise a transport failure.** `LabelManager#manage_labels`,
   `IssueNotifier#hand_ticket_back` and `IssueNotifier#notify_issue` rescue the transport family
   (`GitlabHelpers::TRANSPORT_ERRORS`, spelled out on `ExternalState#notify_stop`'s #115
   precedent), not only `Gitlab::Error::ResponseError`. They already had the contract "a failed
   write is logged and the caller carries on" for an HTTP error; a TCP timeout is the same outage
   in another class. Consequence: after a terminal transition, every remaining effect of the
   sequence is attempted — `finalize_green_done`, `abandon_issue`, `finalize_question`,
   `give_up_reviewing`. Rejected: doing the GitLab writes *before* the transition (it would hand
   a ticket away on a transition `persist_status_change!` then refuses, Autodev #97); wrapping each
   post-transition site separately (four sites today, and the fifth would forget).
   What callers lose: an accidental retry. A pre-transition caller (`finish_merged_mr`,
   `IssueProcessor`'s `apply_label_doing`) used to abort the poll on a TCP timeout and redo the
   write next cycle; it now carries on with the label unwritten, exactly as it already did on a
   GitLab 502.

2. **Clore hands the ticket back when the bot holds it.** `IssuesController#close` closes first,
   then `Autodev::CloseHandback` reads the ticket and, when the bot is an assignee, reassigns it to
   `Issue#handback_target` (`displaced_assignee_id`, else the author — the rule `hand_ticket_back`
   already applies, moved onto the model so both read one definition). The row is closed whatever
   GitLab answers (owner's decision: the off-switch is always available). The outcome
   (`handed_back`, `not_held`, `no_target`, `failed`) is recorded in an `issue.close_handback`
   audit row and told in a flash. No GitLab comment: the ticket asks for the audit note, and a
   human gesture on the dashboard is not autodev speaking.

3. **A label handover hands the ticket to the person who moved the label.** `stop_on_handover` is
   reached only while the bot is still the assignee (`not_ours?` asks that first). The
   `LabelHandover::Verdict` now carries the decisive event's author (`actor_id`), already read to
   tell a human from autodev; the ticket goes to them, else to `handback_target`. The handback
   runs before the stop notice so the notice can say so (`abandon_reassigned` suffix, reused).
   Owner's decision, 28/09.

4. **A health card watches the stock: `held_tickets`.** `Autodev::HeldTicketProbe` runs from
   `AutodevPollJob`, at most every 15 minutes (one `issues?state=opened&assignee_id=<bot>` read per
   project — 2 projects, ≤ 192 reads a day, against the 1 440 a day #118 just removed), and records
   the terminal rows (`done`, `closed`) whose ticket is in that list as an
   `ActivityEvent(kind: 'held_ticket')`, a machinery kind. `HealthReport#check_held_tickets` reads
   it: `warn` (200) naming up to five rows when any, `ok` otherwise; a project GitLab did not
   answer about counts as `unknown`, never as "none held". Observation only (owner's decision): the
   repair gesture is Clore for a `done` row, GitLab for a `closed` one.

## Out of scope

- Re-assigning the 8 tickets: done by hand after the merge, one target per row validated by the
  owner (A#89 and A#124 are approved MRs, see Autodev #90).
- Repairing the three `finished_at` literals: a targeted `UPDATE` in production after the merge.
- `finish_merged_mr` does not hand the ticket back at all. None of the 20 held tickets is a merged
  row, so it is not measured as a cause; the card would show one if it became one.

## Proofs owed (from the ticket)

- Closing a row whose ticket the bot holds hands it back — and closes even when GitLab is down.
- A transport failure during `finalize_green_done` does not leave a `done` row with the ticket on
  the bot.
- The card reports the 8 rows today (dev database, live read-only GitLab) and zero after the
  manual handback.

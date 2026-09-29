# A handover outlives autodev's own label writes (Autodev #101)

## Defect

`Autodev::LabelHandover#verdict` answers "somebody took this ticket back" by
reading the ticket's **current labels** (`suspect`): `label_done` present, a
foreign value in autodev's scope, or `label_doing` gone. The current state is
destructible evidence. Any autodev label write that removes the value erases the
answer, and nothing else keeps a record of it.

The path is still open on master. `LabelManager#apply_label_doing` removes
`other_workflow_labels(doing)`, and `label_done` is on that list. Take a human
who poses `Development::Awaiting Feature Review` (powerpanne's `label_done`) on
a request in `fixing_discussions`. The next `apply_label_doing` (the start of a
fix round) removes that label in the same edit that re-poses `Development::Doing`.
From that point `suspect` finds nothing and the handover is never seen. The
alpha-52 scope clearing was the other door, and #98's correction made it
opt-in. The property itself was never fixed: detection depends on no autodev
write, present or future, removing a value it does not own.

GitLab's resource label events cannot be erased by a later write. They record
who posed or removed which label and when.

## Decision: read the events only when autodev wrote since they were last read

The ticket names three readings. The owner chose the conditional one on
28/09/2026, based on these measurements (production, read-only, same day):

| Figure | Value | Source |
|---|---|---|
| Active rows | 7 (6 `fixing_discussions`, 1 `checking_pipeline`) | `select status, count(*) from issues` |
| Label events on those 7 | 32, 14, 16, 36, 17, 14, 12 → 9 pages of 20 | `resource_label_events`, every page |
| `poll_interval` | 120 s → 720 cycles/day | `~/.autodev/config.yml` |
| GitLab requests/day | 8 330 (27/09), 8 970 (26/09) | `gitlab_request_stats` |
| `edit_issue` writes/week | 48 (labels + assignment) | `gitlab_request_stats`, 21–28/09 |

- **Systematic** (every verdict reads the events): 9 × 720 ≈ **6 500 requests a
  day** at today's 7 rows, about 75 % on top of current traffic, and it grows
  linearly with the number of active rows. The 23/09 triage counted zero active
  rows and called this cost marginal. It no longer is.
- **Conditional** (this spec): the current state can only be erased by an
  autodev write, so the events are read only when autodev has written labels
  since the last time they were read. Cost: one events read (1–2 pages) per autodev
  label write, two when the write came within the floor's margin of a read,
  **≤ ~200 requests a week**.
- **Memorised last-seen labels**: the difference it would trigger on is created
  by autodev's own write, so it reduces to the conditional reading with an extra
  JSON column.

## Mechanism

Two columns on `issues`, both nullable `datetime`:

- `labels_written_at` — stamped by `LabelManager#rewrite_labels` **after** a
  successful `edit_issue`, on the row `(project_path, issue_iid)`. Stamped after
  the write, not before: an events read that starts between a before-stamp and
  the write would count the write as already covered. A crash between the write
  and the stamp loses the trigger. Missing a handover is the lesser harm; the
  class's rule is "everything unknown resolves to do not stop".
- `label_events_seen_until` — the floor: every label event before it has been
  accounted for. Advanced to `t0 − 60 s` (`t0` captured **before** the events
  read) whenever a verdict reads the events and finds no handover. The margin
  exists because an event's `created_at` is GitLab's commit time in
  milliseconds, not autodev's clock, so an edit landing during the read can be
  dated at or before `t0` (concurrency review). Also stamped by an operator
  reset (`reset_for_retry!(reset_budget: true)`): without it, a reviewer's edit
  made while the row sat in `done` was replayed as a handover after the reset's
  own write (adversarial review). Also stamped to `now` when
  a row enters `closed` (an AASM `after_all_transitions` assignment, the same
  way `stamp_pipeline_watch!` works). Evidence before a close has been acted on,
  whoever closed the row. Without this, a dashboard reset of a handed-over row
  would replay the old evidence on its first write and close it again.

Trigger: `labels_written_at && (floor.nil? || labels_written_at > floor)`.
Strictly after: the floor is taken before the read, so a write that lands during
or after the read is later than the floor and fires again on the next cycle, and
one stamped at the floor itself preceded the read. No compare-and-set is needed.
(A first draft used `>=`, which re-read the events on every cycle whenever the
write and the floor fell in the same instant.)

Window: events with `created_at > max(label_events_seen_until, created_at)` of
the row. `created_at` bounds a new row to the life of the row. A first draft also
bounded it by `started_at`. The concurrency review showed that
`IssueProcessor#start_processing` stamps it just *before* the `apply_label_doing`
that erases, so a human edit made between the dispatch and the worker's start
fell outside the window. The migration
backfills `label_events_seen_until = now` on existing rows, so the first write
after deploy does not replay months of history.

Evidence, read off the window's events (the "erased-handover scan"):

1. `done_added` — the last event **by someone else** on `label_done` is an
   `add`.
2. `workflow_moved` — for a label in autodev's scope that is not configured, the
   last event by someone else on it is an `add`.
3. `doing_removed` — the last event by someone else on `label_doing` is a
   `remove`.

Autodev's own events are ignored when looking for "last by someone else". That
is the point: autodev removing the label afterwards does not undo the human's
act. A human removing it again does.

**Neutraliser.** A `done_added` or `workflow_moved` candidate is dropped when
someone else later poses a todo label or `label_doing` (at a `created_at` ≥ the
candidate's). A `doing_removed` candidate is dropped when someone else posed a
todo label **anywhere** in the window, whatever the order: that is
`doing_dropped?`'s rule, and the ff/fast gesture can come as two edits, todo
first (plan review). This is the
"repose the todo label and reassign me" gesture: somebody asking for work is
never a reason to stop, which is `doing_dropped?`'s existing rule extended to
the event history. Same edit counts, because GitLab records a board move as one
event per label with the same timestamp.

Order: done_added, then workflow_moved, then doing_removed, the same as
`suspect`. An event with no user or no `created_at` is never evidence.

## What does not change

- The stage-1 path (candidate in the current labels, confirmed by the last event
  on that label) is unchanged, and a healthy ticket with no autodev write since
  the last read still costs zero calls.
- `moved_since?`, `todo_reapplied_after?` and `scope_residue` are unchanged.
  `moved_since?` serves abandoned rows, where autodev only writes after asking
  it (`ReviewArrearsSweep`).
- Failure rule (Autodev #115): a failed events read raises
  `ApiUnavailableError`, and the floor is not advanced.
- Verdict reasons and locale keys are unchanged (`handover_done_added`,
  `handover_workflow_moved`, `handover_doing_removed`).

The scan lives in `Autodev::LabelHandover::ErasedScan`, a module included in
`LabelHandover`, and it reuses the class's own definitions (`by_someone_else?`,
`scope`, `configured_labels`, `events`) rather than copying them. Only a
persisted `Issue` has clocks, so any other value passed as `row:` gets stages 1
and 2 alone.

`verdict(gl_issue, issue_iid, row: nil)` takes the row as a keyword argument.
Without it, the erased-handover scan is skipped (old behaviour). Its one
production caller, `ExternalState#stop_on_handover`, always passes it.

## The re-arm gate asks before it writes (decided 29/09/2026)

A human edit in the poll cycle before a give-up is erased by the give-up's own
`apply_label_attention`, predates `finished_at`, and sits on a `done` row that
nothing scans. `UntouchedSinceGiveup` looked only after `finished_at`, so it
re-armed the row and reclaimed the ticket, and the scan triggered by the
reclaim's write closed the row one cycle later. The result was two
contradictory comments, and the ticket left on autodev, because `close_row!`
hands nothing back.

The owner compared four answers. Leaving it did the harm above. Stamping the
floor at re-arm lost the handover, as on master. Handing the ticket back at the
close kept the two comments. Asking the scan in the gate was chosen: the gate
declines the re-arm (`LabelHandover#erased_since_floor`, its fourth question).
A clean answer advances the floor, so the reclaim's write replays nothing.
Cost: one events read per gate evaluation. Production has counted 54 give-ups
and 10 sweep re-arms since July.

## Point 3 of the ticket: one source

On the conditional path, detection and authorship are both read from the events.
On the stage-1 path, detection reads the labels and authorship the events. That
split is kept on purpose, because it is what keeps a healthy ticket at zero calls.
The events are memoised for the life of the `LabelHandover` instance, so when
stage 1 has a candidate that turns out to be autodev's own and the scan is due,
both reads use the same fetch.

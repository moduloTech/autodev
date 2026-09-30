# Plan — a handover outlives autodev's own label writes (Autodev #101)

Spec: `docs/superpowers/specs/2026-09-28-a-handover-outlives-autodev-writes-design.md`.
Branch `fix/101-a-handover-outlives-autodev-writes` off `origin/master` (c4fac64,
v1.0.0-alpha.55). Baseline: `bundle exec rake test` → 2777 runs, 0 failures.

Single lane: about six files that all depend on one contract. A parallel split
would cost more than it saves.

## Frozen contract

- Columns `issues.labels_written_at`, `issues.label_events_seen_until`
  (`datetime`, nullable), migration `20260928000001_add_label_event_bookkeeping_to_issues.rb`,
  `if_not_exists: true`, `up` backfills `label_events_seen_until = CURRENT_TIMESTAMP`
  on existing rows.
- `LabelHandover#verdict(gl_issue, issue_iid, row: nil)`.
- `LabelManager#rewrite_labels` stamps `labels_written_at` after `edit_issue`.
- `Issue` stamps `label_events_seen_until = Time.current` on entering `closed`
  (assignment in an `after_all_transitions` callback placed before
  `persist_status_change!`).

## Tasks (TDD: red, then green)

1. **Migration + model.** Test: a row that `close!`es carries
   `label_events_seen_until` ≈ now; a transition to any other state leaves it
   untouched; the migration backfills existing rows and leaves new ones NULL.
2. **LabelManager stamp.** Test: `apply_label_doing` that writes stamps the row;
   a no-op (labels already right, #75) does **not** stamp; a failed `edit_issue`
   does not stamp; a row of another project with the same iid is not stamped.
3. **LabelHandover scan.**
   - `events` memoised per instance, `t0` captured before the first fetch.
   - `verdict`: stage 1 as today. When it yields no confirmed handover and
     `row` is due, run the scan. On "no handover", advance the floor to `t0`.
   - Scan evidence, order and neutraliser as in the spec.
4. **ExternalState** passes `row: issue`.
5. **Docs**: CLAUDE.md "Key Design Decisions" handover bullet + "SQLite Schema"
   list if it lists columns, CHANGELOG `[Unreleased]`.

## Tests to write (behavioural)

- The case itself, end to end through `ExternalState#not_ours?`: human poses
  `label_done`, autodev's `apply_label_doing` removes it (real `LabelManager` on a
  stub client), the next `not_ours?` closes the row with `handover_done_added`.
- Same for `workflow_moved` (a foreign scoped value removed by an autodev write
  with `clear_scope`) and `doing_removed`.
- No write since the floor → zero `issue_label_events` calls on a healthy ticket.
- Write since the floor, no human event → one events read, verdict nil, floor
  advanced to the pre-read time, a second verdict right after reads nothing.
- Neutraliser: human removes `label_doing` and poses the todo label in one edit
  (ff/fast shape) → no handover. A human poses `label_done`, then later
  re-poses the todo label → no handover.
- A human's add later undone by the same human's remove → no handover.
- Evidence before the floor, or before `started_at`, is ignored.
- Events read fails → raises `ApiUnavailableError`, floor untouched.
- `row:` omitted → the scan never runs (old behaviour kept for the other callers).

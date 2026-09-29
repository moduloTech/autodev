# frozen_string_literal: true

# The two clocks `LabelHandover`'s erased-handover scan runs on (Autodev #101).
#
# `labels_written_at` — when autodev last rewrote this ticket's labels. That
# write is the only thing that can erase the evidence `LabelHandover#suspect`
# reads off the current labels, so it is what makes reading the events due.
#
# `label_events_seen_until` — every label event before it has been accounted
# for: advanced when a scan reads the events and finds no handover, and stamped
# when a row enters `closed`. Backfilled to now on the rows that exist when this
# runs, so the first write after the deploy does not replay months of history.
#
# `if_not_exists: true` like every migration here — the production database
# predates ActiveRecord and `config/initializers/auto_migrate.rb` re-runs the
# whole set on every boot. The backfill only fills NULL, so a re-run is a no-op.
class AddLabelEventBookkeepingToIssues < ActiveRecord::Migration[8.1]
  def up
    add_column :issues, :labels_written_at, :datetime, if_not_exists: true
    add_column :issues, :label_events_seen_until, :datetime, if_not_exists: true
    execute <<~SQL.squish
      UPDATE issues SET label_events_seen_until = CURRENT_TIMESTAMP WHERE label_events_seen_until IS NULL
    SQL
  end

  def down
    remove_column :issues, :label_events_seen_until, if_exists: true
    remove_column :issues, :labels_written_at, if_exists: true
  end
end

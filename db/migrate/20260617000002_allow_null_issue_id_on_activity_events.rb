# frozen_string_literal: true

# Relax `activity_events.issue_id` to allow NULL.
#
# The column was created NOT NULL (db/migrate/20260608000002), but the model
# has always declared `belongs_to :issue, optional: true`. System-level events
# — the poller heartbeat (`kind: 'poller'`) and cycle-failure markers
# (`kind: 'error'`) emitted by AutodevPollJob — aren't tied to any issue, so
# they need a nullable FK. (SQLite rebuilds the table here; data is preserved.)
class AllowNullIssueIdOnActivityEvents < ActiveRecord::Migration[8.1]
  def up
    change_column_null :activity_events, :issue_id, true
  end

  def down
    change_column_null :activity_events, :issue_id, false
  end
end

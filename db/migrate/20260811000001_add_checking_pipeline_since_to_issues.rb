# frozen_string_literal: true

# The clock behind the absolute age bound on a pipeline watch (Autodev #53).
#
# `checking_pipeline_since` holds the instant a row entered `checking_pipeline`,
# NULL everywhere else. `Issue#stamp_pipeline_watch!` writes it on every AASM
# transition; `PipelineMonitor::PollTracker` seeds it for the rows that arrive
# by `update_all` (`revive_stalled!`, `reset_for_retry!`).
#
# `if_not_exists: true` like every migration here — the production database
# predates ActiveRecord and `config/initializers/auto_migrate.rb` re-runs the
# whole set on every boot.
class AddCheckingPipelineSinceToIssues < ActiveRecord::Migration[8.1]
  # Rows already sitting in the state when this ships would otherwise start a
  # fresh grace period at the release — deferring the whole point of the ticket
  # by `pipeline_watch_max_days`, on exactly the tickets that motivated it
  # (production's #15894 had been polling long enough to write 29 773 events).
  #
  # The newest `transition` activity event *is* the last transition, so it
  # reconstructs the real entry instant; `issues.created_at` covers a row that
  # has none. Guarded on the status and on `IS NULL`, so the statement is
  # idempotent and a re-run never moves a stamp the runtime has since written.
  BACKFILL = <<~SQL.squish
    UPDATE issues
       SET checking_pipeline_since = COALESCE(
             (SELECT MAX(created_at) FROM activity_events
               WHERE activity_events.issue_id = issues.id
                 AND activity_events.kind = 'transition'),
             issues.created_at)
     WHERE status = 'checking_pipeline'
       AND checking_pipeline_since IS NULL
  SQL

  def up
    add_column :issues, :checking_pipeline_since, :datetime, if_not_exists: true
    execute BACKFILL
  end

  def down
    remove_column :issues, :checking_pipeline_since, if_exists: true
  end
end

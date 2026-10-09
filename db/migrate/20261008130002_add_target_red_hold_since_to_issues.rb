# frozen_string_literal: true

# When the hold on a merge request pipeline the target branch keeps red began
# (Autodev #130, owner's decision of 09/10/2026: the hold has its own clock).
#
# The hold used to be bounded by `checking_pipeline_since`, the watch's clock:
# a row already watched for longer than `pipeline_watch_max_days` gave up under
# `target_pipeline_red` on the very poll its hold began, having waited for
# nothing. Stamped by the poll that begins a hold, kept while it goes on, and
# cleared with `target_red_hold_pipeline_id`. NULL means no hold, or one
# recorded before this column existed — the next poll that holds stamps it.
#
# `if_not_exists: true` like every migration here — the production database
# predates ActiveRecord and `config/initializers/auto_migrate.rb` re-runs the
# whole set on every boot.
class AddTargetRedHoldSinceToIssues < ActiveRecord::Migration[8.1]
  def up
    add_column :issues, :target_red_hold_since, :datetime, if_not_exists: true
  end

  def down
    remove_column :issues, :target_red_hold_since, if_exists: true
  end
end

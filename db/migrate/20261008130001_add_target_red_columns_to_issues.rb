# frozen_string_literal: true

# A merge request pipeline whose every red job is already red, for the same
# reason, on the target branch (Autodev #130).
#
# `target_red_hold_pipeline_id` is the merge request pipeline the row is holding
# while the target is red: nothing is fixed on it, and the first poll on which
# the target no longer explains every red job retries it. NULL means no hold.
#
# `target_red_hold_key` is "<target pipeline id>:<red job ids>" of the poll that
# held: a later poll on the same two pipelines has the same answer and does not
# read the two traces again (up to 4 MiB each, every poll interval).
#
# `preexisting_noted_key` is "<merge request pipeline id>:<job names>" of the
# last comment posted on the merge request about pre-existing jobs, so that a
# hold lasting days posts it once.
#
# `if_not_exists: true` like every migration here — the production database
# predates ActiveRecord and `config/initializers/auto_migrate.rb` re-runs the
# whole set on every boot.
class AddTargetRedColumnsToIssues < ActiveRecord::Migration[8.1]
  def up
    add_column :issues, :target_red_hold_pipeline_id, :integer, if_not_exists: true
    add_column :issues, :target_red_hold_key, :string, if_not_exists: true
    add_column :issues, :preexisting_noted_key, :string, if_not_exists: true
  end

  def down
    remove_column :issues, :target_red_hold_pipeline_id, if_exists: true
    remove_column :issues, :target_red_hold_key, if_exists: true
    remove_column :issues, :preexisting_noted_key, if_exists: true
  end
end

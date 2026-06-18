# frozen_string_literal: true

# Adds the "done but a human still needs to act" marker to issues.
#
# Autodev has four give-up paths that transition an issue to `done` while a
# manual intervention is still required on GitLab (review-round limit reached,
# mr-review failures exhausted, pipeline stagnation, discussion stagnation).
# Until now nothing distinguished such a "gave-up done" from a clean delivery,
# so the dashboard showed both as a green "Livrée" and the "À surveiller"
# surfaces never listed them. `needs_attention` flags the row; `attention_reason`
# stores which give-up path fired (matches the notification key already posted
# on the MR: review_limit_reached / review_failures_exhausted /
# stagnation_pipeline / stagnation_discussions). Both are cleared on reentry
# and on a manual reset.
#
# `if_not_exists`-aware so it's a no-op on a DB that already has the columns.
class AddNeedsAttentionToIssues < ActiveRecord::Migration[8.1]
  def up
    add_column :issues, :needs_attention, :boolean, null: false, default: false, if_not_exists: true
    add_column :issues, :attention_reason, :string, if_not_exists: true
  end

  def down
    remove_column :issues, :needs_attention, if_exists: true
    remove_column :issues, :attention_reason, if_exists: true
  end
end

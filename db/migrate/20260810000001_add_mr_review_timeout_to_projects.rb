# frozen_string_literal: true

# Per-project cap for one `mr-review` run (Autodev #54). Separate from
# `dc_timeout` on measured grounds: on the production copy, 317 completed reviews
# ran up to 2641s *successfully*, against dc_timeout's 1800s default — reusing it
# would have killed a good review roughly once a quarter, and because
# review_count only increments on success each kill costs five reruns and ends in
# a false review_failures_exhausted.
#
# `if_not_exists`-aware so it is a no-op on a DB that already has the column,
# matching the other project-config migrations.
class AddMrReviewTimeoutToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :mr_review_timeout, :integer, if_not_exists: true
  end
end

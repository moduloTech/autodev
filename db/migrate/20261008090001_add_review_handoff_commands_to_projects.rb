# frozen_string_literal: true

# The project's own measurement and draw scripts that autodev runs on a
# delivered merge request before it writes the review labels, the reviewer and
# the assignee itself (Autodev #90). JSON command arrays, like `post_completion`.
#
# All three nullable: a project that declares nothing gets nothing written, as
# before. `review_size_command` is the switch — the other two are refused
# without it (`Project#validate_review_handoff_pairing`).
class AddReviewHandoffCommandsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :review_size_command, :json, if_not_exists: true
    add_column :projects, :review_coverage_command, :json, if_not_exists: true
    add_column :projects, :reviewer_draw_command, :json, if_not_exists: true
  end
end

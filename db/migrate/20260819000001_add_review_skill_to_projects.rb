# frozen_string_literal: true

# The skill the review step loads from the cloned repo (Autodev #74).
#
# Nullable and optional. The name differs per project — `mr-review` is the
# author-side skill on powerpanne/core, while on ff/fast/core the author-side one
# is `prepare-mr` and `mr-review` is the *reviewer* skill, which would be the
# wrong role. That is why this is declared rather than discovered by convention.
# Unset means the `mr-review` binary, which stays the right answer where no
# project skill exists.
class AddReviewSkillToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :review_skill, :string, if_not_exists: true
  end
end

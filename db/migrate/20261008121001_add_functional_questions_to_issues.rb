# frozen_string_literal: true

# A functional divergence found in review becomes a question on the ticket
# (Autodev #121).
#
# `functional_questions` — the review threads autodev asked the requester about,
# as a JSON object `{ "<discussion_id>" => "<ISO8601 UTC time asked>" }`. A thread
# in it is never asked again on this merge request: once answered it is an
# ordinary thread to fix, and its prompt quotes the ticket's notes posted after
# the time recorded here. NULL means none. Cleared by `reenter`, which rebuilds
# the branch.
#
# `clarification_resume_to` — where the answer to the clarification sends the
# row: NULL is `pending` (a spec clarification, the #75 path), `fixing_discussions`
# a functional question on the merge request. Read by `clarification_received`'s
# guard, cleared by the first round that resumes on the merge request.
#
# `if_not_exists: true` like every migration here — the production database
# predates ActiveRecord and `config/initializers/auto_migrate.rb` re-runs the
# whole set on every boot.
class AddFunctionalQuestionsToIssues < ActiveRecord::Migration[8.1]
  def up
    add_column :issues, :functional_questions, :text, if_not_exists: true
    add_column :issues, :clarification_resume_to, :string, if_not_exists: true
  end

  def down
    remove_column :issues, :functional_questions, if_exists: true
    remove_column :issues, :clarification_resume_to, if_exists: true
  end
end

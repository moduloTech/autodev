# frozen_string_literal: true

# How many discussion-fix rounds this request has had, and only those
# (Autodev #99, review of the alpha-52 lot).
#
# `fix_round` counts two loops that do not measure the same thing: `FixCycle`
# counts rounds of unresolved threads, `PipelineMonitor::PipelineFixer` counts
# attempts at failing jobs, and nothing resets it when a request moves from one
# to the other. `MrFixer#fix_round_ceiling` is a sentence about the *discussion*
# loop — "the guard that bounds it should have fired long before here" — so it
# has to read a number that counts that loop and nothing else. Reading the shared
# one gave up healthy requests: thirteen pipeline rounds, each on a different
# failing job so the pipeline's own guard never counted to its threshold, then
# two discussion rounds, and the ceiling fired with a comment blaming a guard
# that had counted twice.
#
# `fix_round` keeps its meaning and its readers — the round number in the log
# line, in the GitLab notification, and in the dashboard — because those are
# about the work done on a request, which is exactly the sum of the two loops.
#
# `if_not_exists: true` like every migration here — the production database
# predates ActiveRecord and `config/initializers/auto_migrate.rb` re-runs the
# whole set on every boot.
class AddDiscussionFixRoundToIssues < ActiveRecord::Migration[8.1]
  # Existing rows start at 0 rather than inheriting `fix_round`: a request in
  # flight when this ships has a `fix_round` made of both loops, and seeding the
  # new column from it would carry the very conflation the column removes.
  # Starting them over costs at most one extra ceiling's worth of rounds, once.
  def up
    add_column :issues, :discussion_fix_round, :integer, null: false, default: 0, if_not_exists: true
  end

  def down
    remove_column :issues, :discussion_fix_round, if_exists: true
  end
end

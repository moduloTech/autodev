# frozen_string_literal: true

# When `dispatch_done_unassigned` reserved this delivery's `post_completion`
# hook (Autodev #114).
#
# The hook's precondition survives its own work: `start_post_completion!` ->
# `post_completion_done!` returns the row to `done`, the MR is still open and the
# ticket still unassigned, so the pass used to re-run the command on every cycle
# — every 120 s at production's `poll_interval`. The pass now writes the state it
# selects on, the way `infra_recheck_at` does for the infra recheck (Autodev
# #110): NULL means "not dispatched for this delivery", and the reentry paths
# clear it, because a new delivery is a new deploy.
#
# `if_not_exists: true` like every migration here — the production database
# predates ActiveRecord and `config/initializers/auto_migrate.rb` re-runs the
# whole set on every boot. Not backfilled: an unstamped `done` row is a delivery
# whose hook has not run, which is what the pass selected already.
class AddPostCompletionDispatchedAtToIssues < ActiveRecord::Migration[8.1]
  def up
    add_column :issues, :post_completion_dispatched_at, :datetime, if_not_exists: true
  end

  def down
    remove_column :issues, :post_completion_dispatched_at, if_exists: true
  end
end

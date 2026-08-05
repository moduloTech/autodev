# frozen_string_literal: true

# Adds the bookkeeping columns for the bounded second-chance recovery of
# tickets whose retry budget is spent (Autodev #34, follow-up of #33).
#
# Exhausting `max_retries` is the right outcome for a genuine code failure, but
# not for a transient one — a network blip, a GitLab/registry outage, the
# `git push` stale-info case from #33. Those were terminal: nothing re-attempted
# the row once the cause disappeared, so it sat in `error` forever and needed a
# manual UPDATE (the orphan pattern #31 fixed for infra stagnations).
#
# `dispatch_error_recheck` re-arms the spent budget instead of reimplementing
# the retry mechanics. `error_recheck_count` caps how many extra rounds a single
# ticket can ever be granted, so a real code failure burns the cap and then
# rests terminal rather than looping; `error_recheck_at` spaces the grants out,
# exactly as `infra_recheck_at` does for the infra recheck.
#
# `if_not_exists`-aware so it's a no-op on a DB that already has the columns.
class AddErrorRecheckToIssues < ActiveRecord::Migration[8.1]
  def up
    add_column :issues, :error_recheck_count, :integer, null: false, default: 0, if_not_exists: true
    add_column :issues, :error_recheck_at, :datetime, if_not_exists: true
  end

  def down
    remove_column :issues, :error_recheck_count, if_exists: true
    remove_column :issues, :error_recheck_at, if_exists: true
  end
end

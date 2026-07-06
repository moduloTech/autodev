# frozen_string_literal: true

# Adds the bookkeeping columns for the automatic infra-recovery recheck.
#
# When a ticket stagnates on an INFRA/deploy failure it ends `done` +
# `needs_attention: true` + `attention_reason: 'stagnation_pipeline'` and, until
# now, was never re-attempted once the underlying CI recovered (real case: 17
# MRs stayed blocked long after the werf binary was fixed). The new
# `dispatch_infra_recheck` pass re-classifies such a ticket's CURRENT head
# pipeline and, if CI has recovered, re-enters the pipeline-check flow.
#
# `infra_recheck_count` caps the number of automatic rechecks (default cap 5)
# so a never-recovering infra failure self-limits and stays in needs_attention
# permanently instead of looping. `infra_recheck_at` spaces the rechecks out
# (backoff) exactly like `next_retry_at` gates the error-retry path.
#
# `if_not_exists`-aware so it's a no-op on a DB that already has the columns.
class AddInfraRecheckToIssues < ActiveRecord::Migration[8.1]
  def up
    add_column :issues, :infra_recheck_count, :integer, null: false, default: 0, if_not_exists: true
    add_column :issues, :infra_recheck_at, :datetime, if_not_exists: true
  end

  def down
    remove_column :issues, :infra_recheck_count, if_exists: true
    remove_column :issues, :infra_recheck_at, if_exists: true
  end
end

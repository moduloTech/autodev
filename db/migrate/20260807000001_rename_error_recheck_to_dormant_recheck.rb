# frozen_string_literal: true

# Widens the bounded second-chance bookkeeping from `error` rows only (#34) to
# every dormant row — orphaned `pending` (#47) and worker-pruned active states
# included. The columns change name, not meaning: they already carried "how many
# bounded second chances this row has been granted, and when the next one is
# due". Renaming keeps a single counter per row instead of two counters with
# overlapping semantics.
#
# `column_exists?`-guarded so it is a no-op on a DB that was already migrated —
# `config/initializers/auto_migrate.rb` runs this on every boot.
class RenameErrorRecheckToDormantRecheck < ActiveRecord::Migration[8.1]
  def up
    rename_column :issues, :error_recheck_count, :dormant_recheck_count if column_exists?(:issues, :error_recheck_count)
    rename_column :issues, :error_recheck_at, :dormant_recheck_at if column_exists?(:issues, :error_recheck_at)
  end

  def down
    rename_column :issues, :dormant_recheck_count, :error_recheck_count if column_exists?(:issues,
                                                                                          :dormant_recheck_count)
    rename_column :issues, :dormant_recheck_at, :error_recheck_at if column_exists?(:issues, :dormant_recheck_at)
  end
end

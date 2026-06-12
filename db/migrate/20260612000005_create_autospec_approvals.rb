# frozen_string_literal: true

# Phase D step 9 — AutoSpec approvals (cf. autodev/docs/autospec.md §E, §J).
#
# One vote by one owner on a draft at a given iteration. The iteration is
# snapshotted from `autospec_drafts.current_iteration` at vote time so a
# `pending_approval → drafting` (retract) followed by a re-submit
# increments the draft's iteration and the previous approvals are
# automatically invalidated — they reference the older iteration and the
# orchestration service's quorum check only counts rows matching the
# current iteration.
#
# The unique index on (autospec_draft_id, user_id, iteration) prevents
# double-voting at the DB level (defense in depth — the model also
# validates uniqueness). The `action` column is a string ('approved' |
# 'rejected'); `reason` is required when action='rejected' (validated
# at the model level — SQLite doesn't carry partial CHECK constraints
# we can rely on).
class CreateAutospecApprovals < ActiveRecord::Migration[8.1]
  def change
    create_autospec_approvals_table
    add_autospec_approvals_index
  end

  private

  def create_autospec_approvals_table
    create_table :autospec_approvals, if_not_exists: true do |t|
      t.references :autospec_draft, null: false, foreign_key: true
      t.references :user,           null: false, foreign_key: true
      t.integer  :iteration, null: false
      t.string   :action,    null: false
      t.text     :reason
      t.datetime :acted_at, null: false
    end
  end

  def add_autospec_approvals_index
    add_index :autospec_approvals,
              %i[autospec_draft_id user_id iteration],
              unique: true,
              name: 'idx_autospec_approvals_uniqueness',
              if_not_exists: true
  end
end

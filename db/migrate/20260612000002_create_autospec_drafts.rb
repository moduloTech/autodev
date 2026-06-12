# frozen_string_literal: true

# Phase D step 9 — AutoSpec drafts (cf. autodev/docs/autospec.md §A, §E).
#
# One row per ticket-in-the-making. The author edits in `drafting`, submits
# to `pending_approval`, owners vote (rows in `autospec_approvals`), and on
# quorum the orchestration service (step 11) flips to `submitted` and
# stamps the GitLab pointer. See §E for the full lifecycle diagram.
#
# `status` is a string column so AASM (which already drives `Issue#status`)
# can use the same first-class adapter — autospec.md §E sketched an integer
# enum, but consistency with the Issue model trumps that small saving for 4
# values. `current_iteration` lets approvals "snapshot" the iteration at
# vote time so a retract → resubmit invalidates old approvals cleanly.
#
# `destination` is nullable: §J defines it as set at the
# `drafting → pending_approval` transition (the author picks "human" or
# "autodev" at submission), so the column carries no value while drafting.
# The model enforces the inclusion validation when present.
class CreateAutospecDrafts < ActiveRecord::Migration[8.1]
  def change
    create_autospec_drafts_table
    add_autospec_drafts_indexes
  end

  private

  def create_autospec_drafts_table
    create_table :autospec_drafts, if_not_exists: true do |t|
      autospec_drafts_authoring_columns(t)
      autospec_drafts_submission_columns(t)
      t.timestamps
    end
  end

  def autospec_drafts_authoring_columns(table)
    table.references :user,    null: false, foreign_key: true
    table.references :project, null: false, foreign_key: true
    table.string  :status,            null: false, default: 'drafting'
    table.integer :current_iteration, null: false, default: 0
    table.string :title
    table.text   :markdown
    table.json   :meta_chips, default: {}
    table.string :destination
  end

  def autospec_drafts_submission_columns(table)
    table.datetime :submitted_at
    table.integer  :gitlab_issue_iid
    table.string   :gitlab_issue_url
  end

  def add_autospec_drafts_indexes
    add_index :autospec_drafts, %i[user_id status],
              name: 'idx_autospec_drafts_user_status',
              if_not_exists: true
    add_index :autospec_drafts, %i[project_id status],
              name: 'idx_autospec_drafts_project_status',
              if_not_exists: true
  end
end

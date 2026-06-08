# frozen_string_literal: true

# Materializes the `issues` and `activity_events` tables as AR-managed
# schema (railsification step 2 second half). Both tables existed before
# this migration — the legacy `Database::Migration.run` created them via
# raw SQL on Sequel boot. This migration is `if_not_exists`-aware so it's
# a no-op on prod DBs where they're already present; on a fresh install
# it creates them outright.
#
# The legacy module also ran defensive UPDATEs on every boot to rename
# pre-v0.10 status values; we keep that here as data hygiene so any
# old rows that escaped earlier migrations get fixed up the first time
# this migration runs.
class CreateIssuesAndActivityEvents < ActiveRecord::Migration[8.1]
  STATUS_RENAMES = {
    'mr_pipeline_running' => 'checking_pipeline',
    'mr_fixing' => 'fixing_discussions',
    'mr_pipeline_fixing' => 'fixing_pipeline',
    'over' => 'done',
    'blocked' => 'pending'
  }.freeze

  def up
    create_issues_table
    backfill_optional_columns
    create_activity_events_table
    rename_legacy_statuses
  end

  def down
    drop_table :activity_events, if_exists: true
    drop_table :issues, if_exists: true
  end

  private

  def create_issues_table # rubocop:disable Metrics/MethodLength
    create_table :issues, if_not_exists: true do |t|
      t.string  :project_path,            null: false
      t.integer :issue_iid,               null: false
      t.string  :issue_title
      t.string  :branch_name
      t.string  :status, null: false, default: 'pending'
      t.integer :mr_iid
      t.string  :mr_url
      t.text    :error_message
      t.datetime :created_at,             null: false, default: -> { "datetime('now')" }
      t.index %i[project_path issue_iid], unique: true
    end
  end

  # The Sequel module appended columns one at a time as the project grew;
  # mirror them all idempotently so a fresh install ends up with the same
  # final shape an old prod DB has.
  def backfill_optional_columns # rubocop:disable Metrics/MethodLength
    add_column :issues, :dc_stdout, :text, if_not_exists: true
    add_column :issues, :dc_stderr, :text, if_not_exists: true
    add_column :issues, :retry_count, :integer, null: false, default: 0, if_not_exists: true
    add_column :issues, :next_retry_at, :string, if_not_exists: true
    add_column :issues, :clarification_requested_at, :string, if_not_exists: true
    add_column :issues, :fix_round, :integer, null: false, default: 0, if_not_exists: true
    add_column :issues, :pipeline_retrigger_count, :integer, null: false, default: 0, if_not_exists: true
    add_column :issues, :issue_author_id, :integer, if_not_exists: true
    add_column :issues, :post_completion_error, :text, if_not_exists: true
    add_column :issues, :locale, :string, default: 'fr', if_not_exists: true
    add_column :issues, :activity_note_id, :integer, if_not_exists: true
    add_column :issues, :pipeline_poll_since, :string, if_not_exists: true
    add_column :issues, :review_count, :integer, null: false, default: 0, if_not_exists: true
    add_column :issues, :stagnation_signatures, :text, if_not_exists: true
    add_column :issues, :review_failure_count, :integer, null: false, default: 0, if_not_exists: true
    add_column :issues, :started_at, :string, if_not_exists: true
    add_column :issues, :finished_at, :string, if_not_exists: true
  end

  def create_activity_events_table # rubocop:disable Metrics/MethodLength
    create_table :activity_events, if_not_exists: true do |t|
      t.integer  :issue_id,     null: false
      t.datetime :created_at,   null: false, default: -> { "datetime('now')" }
      t.string   :kind,         null: false
      t.string   :level,        null: false, default: 'info'
      t.text     :payload_json, null: false, default: '{}'
    end
    add_index :activity_events, %i[issue_id created_at], if_not_exists: true,
                                                         name: 'idx_ae_issue'
    add_index :activity_events, %i[kind created_at], if_not_exists: true,
                                                     name: 'idx_ae_kind'
  end

  def rename_legacy_statuses
    STATUS_RENAMES.each do |old_status, new_status|
      execute("UPDATE issues SET status = '#{new_status}' WHERE status = '#{old_status}'")
    end
    execute(
      "UPDATE issues SET status = 'checking_pipeline' " \
      "WHERE status = 'mr_fixed' AND mr_iid IS NOT NULL"
    )
    execute("UPDATE issues SET status = 'done' WHERE status = 'mr_fixed'")
  end
end

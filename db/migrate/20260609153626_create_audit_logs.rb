# frozen_string_literal: true

# PR1 of the users-rollout chantier (cf. docs/users-rollout.md §6).
#
# Platform-wide audit trail. Captures manual write actions (reset,
# transition) with the acting user and automatic AASM transitions
# (actor_id NULL) on Issue. PR2 will add membership.granted/revoked/
# role_changed and user.created/disabled/reactivated entries from the
# GitLab sync + admin lifecycle paths.
#
# Orthogonal to `activity_events`: that table feeds the issue-centric
# timeline UI; this one is platform-wide and action-centric. They are
# not redundant — `activity_events` answers "what happened to this
# issue?", `audit_logs` answers "who did what when?".
class CreateAuditLogs < ActiveRecord::Migration[8.1]
  def change
    create_audit_logs_table
    add_audit_logs_indexes
  end

  private

  def create_audit_logs_table
    create_table :audit_logs, if_not_exists: true do |t|
      t.string  :resource_type, null: false
      t.bigint  :resource_id,   null: false
      t.string  :action,        null: false
      t.references :actor, foreign_key: { to_table: :users }, null: true
      t.json :payload, null: false, default: {}
      t.datetime :created_at, null: false, default: -> { "datetime('now')" }
    end
  end

  def add_audit_logs_indexes
    add_index :audit_logs, %i[resource_type resource_id],
              name: 'idx_audit_logs_resource', if_not_exists: true
    add_index :audit_logs, :created_at,
              name: 'idx_audit_logs_created_at', if_not_exists: true
  end
end

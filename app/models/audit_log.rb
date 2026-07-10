# frozen_string_literal: true

# Platform-wide audit row. See `docs/users-rollout.md` §2 for the action
# catalog and `app/services/audit.rb` for the canonical write path.
#
# `resource` is polymorphic — Issue / ProjectMembership / User / Project in
# the current set, anything else is fair game for future actions.
# `actor` is nullable: NULL means the action was performed by the
# system (poller, recurring job, AASM transition fired by a job).
class AuditLog < ApplicationRecord
  ACTIONS = %w[
    issue.reset_manual
    issue.transition_manual
    issue.transition_auto
    issue.deploy_review
    deploy_review.manual
    membership.granted
    membership.revoked
    membership.role_changed
    user.created
    user.disabled
    user.reactivated
    project.owner_granted
    project.owner_revoked
  ].freeze

  # SQLite has no native JSON type; `t.json` in the migration maps to TEXT
  # storage, but AR needs the attribute to be typed :json for the Hash ↔
  # JSON round-trip to happen transparently on reads.
  attribute :payload, :json, default: {}

  belongs_to :actor, class_name: 'User', optional: true
  belongs_to :resource, polymorphic: true

  validates :resource_type, presence: true
  validates :resource_id, presence: true
  validates :action, presence: true, inclusion: { in: ACTIONS }
end

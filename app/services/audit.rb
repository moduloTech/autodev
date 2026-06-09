# frozen_string_literal: true

# Canonical entry point for `audit_logs` writes. Used today by:
#
# - `IssuesController#reset` + `#transition` (manual actions, actor = current_user).
# - `Issue#emit_audit_log!` (AASM `after_all_transitions`, manual or automatic).
#
# PR2 adds the membership.* and user.* callers from `GitlabMembershipSync`
# and the rake/admin paths.
#
# Best-effort: a write failure is logged and swallowed. The audit log
# must never block the calling code path — losing an audit row is bad,
# but breaking a state machine transition or a controller response would
# be worse.
module Audit
  module_function

  def record!(resource:, action:, actor: nil, payload: {}) # rubocop:disable Metrics/MethodLength
    AuditLog.create!(
      resource_type: resource.class.name,
      resource_id: resource.id,
      action: action,
      actor: actor,
      payload: payload
    )
  rescue StandardError => e
    Rails.logger.warn(
      "[audit] failed to record #{action} on #{resource.class.name}##{resource.id}: #{e.class}: #{e.message}"
    )
    nil
  end
end

# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# Integration test for the audit fan-out on the two write actions of
# IssuesController. PR3 (alpha.7+) turned on the global gating, so we
# sign in an admin to reach the actions — the audit row is expected to
# carry the actor_id of the signed-in user.
class IssuesControllerAuditTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)
    @issue = Issue.create!(project_path: 'group/proj', issue_iid: 500, status: 'error',
                           error_message: 'boom', retry_count: 2)
    sign_in @admin
  end

  def test_reset_writes_audit_log_pointing_at_issue
    post "/issues/#{@issue.id}/reset"
    log = AuditLog.where(action: 'issue.reset_manual').last

    assert_not_nil log
    assert_equal @admin.id, log.actor_id
    assert_equal @issue.id, log.resource_id
  end

  def test_reset_payload_captures_previous_state_and_iid
    post "/issues/#{@issue.id}/reset"
    payload = AuditLog.where(action: 'issue.reset_manual').last.payload

    assert_equal 'error', payload['previous_state']
    assert_equal 500, payload['iid']
  end

  def test_transition_writes_manual_audit_log
    pending_issue = Issue.create!(project_path: 'group/proj', issue_iid: 501, status: 'pending')

    post "/issues/#{pending_issue.id}/transition", params: { event: 'start_processing' }
    log = AuditLog.where(action: 'issue.transition_manual').last

    assert_not_nil log
    assert_equal @admin.id, log.actor_id
  end

  def test_transition_payload_includes_event_and_states
    pending_issue = Issue.create!(project_path: 'group/proj', issue_iid: 502, status: 'pending')

    post "/issues/#{pending_issue.id}/transition", params: { event: 'start_processing' }
    payload = AuditLog.where(action: 'issue.transition_manual').last.payload

    assert_equal 'pending', payload['from']
    assert_equal 'cloning', payload['to']
    assert_equal 'start_processing', payload['event']
  end

  def test_transition_rejects_forbidden_event_and_writes_no_audit_log
    post "/issues/#{@issue.id}/transition", params: { event: 'commit_complete' }

    assert_response :unprocessable_entity
    assert_equal 0, AuditLog.where(resource_id: @issue.id).count
  end
end

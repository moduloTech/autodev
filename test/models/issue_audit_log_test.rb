# frozen_string_literal: true

require_relative '../rails_helper'

# Coverage of Issue#emit_audit_log!, the audit-trail half of the AASM
# after_all_transitions chain. Sibling to `emit_activity_event!` which
# already had a stable contract pre-PR1.
class IssueAuditLogTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: 'marc@modulotech.fr', name: 'Marc')
    @issue = Issue.create!(project_path: 'group/proj', issue_iid: 100, status: 'pending')
  end

  def test_automatic_transition_records_with_null_actor
    @issue.start_processing!

    log = AuditLog.where(action: 'issue.transition_auto').last

    assert_not_nil log
    assert_nil log.actor_id
    assert_equal @issue.id, log.resource_id
  end

  def test_automatic_transition_payload_includes_event_and_states
    @issue.start_processing!

    payload = AuditLog.where(action: 'issue.transition_auto').last.payload

    assert_equal 'pending', payload['from']
    assert_equal 'cloning', payload['to']
    assert_equal 'start_processing', payload['event']
  end

  def test_manual_transition_records_actor_and_distinct_action
    @issue._audit_actor = @user
    @issue._audit_origin = :manual

    @issue.start_processing!

    log = AuditLog.where(action: 'issue.transition_manual').last

    assert_not_nil log
    assert_equal @user.id, log.actor_id
    assert_equal 'cloning', log.payload['to']
  end

  def test_manual_flags_cleared_after_transition
    @issue._audit_actor = @user
    @issue._audit_origin = :manual
    @issue.start_processing!

    # A subsequent automatic transition must NOT inherit the previous
    # _audit_actor — the hook resets the flags in an `ensure` block.
    @issue.clone_complete!

    last = AuditLog.order(:id).last

    assert_equal 'issue.transition_auto', last.action
    assert_nil last.actor_id
  end

  def test_audit_failure_does_not_block_aasm_transition
    # Force Audit.record! to raise — the transition must still complete
    # and the new state must persist.
    Audit.stub(:record!, ->(**) { raise 'boom' }) do
      @issue.start_processing!
    end

    assert_equal 'cloning', @issue.reload.status
  end
end

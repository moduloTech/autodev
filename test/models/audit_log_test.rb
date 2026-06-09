# frozen_string_literal: true

require_relative '../rails_helper'

class AuditLogTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: 'admin@modulotech.fr', name: 'Admin')
    @issue = Issue.create!(project_path: 'group/proj', issue_iid: 42, status: 'pending')
  end

  def test_action_must_be_in_known_list
    log = AuditLog.new(resource: @issue, action: 'issue.unknown_event')

    refute_predicate log, :valid?
    assert_includes log.errors[:action], 'is not included in the list'
  end

  def test_resource_and_action_required
    refute_predicate AuditLog.new(action: 'issue.reset_manual'), :valid?
    refute_predicate AuditLog.new(resource: @issue), :valid?
  end

  def test_polymorphic_resource_persists_type_and_id
    log = AuditLog.create!(resource: @issue, action: 'issue.reset_manual', actor: @user)

    assert_equal 'Issue', log.resource_type
    assert_equal @issue.id, log.resource_id
  end

  def test_polymorphic_resource_reads_back_as_object
    log = AuditLog.create!(resource: @issue, action: 'issue.reset_manual', actor: @user)

    assert_equal @issue, log.resource
    assert_equal @user, log.actor
  end

  def test_payload_round_trips_as_hash
    log = AuditLog.create!(
      resource: @issue, action: 'issue.transition_auto',
      payload: { from: 'pending', to: 'cloning', event: 'start_processing' }
    )

    assert_equal({ 'from' => 'pending', 'to' => 'cloning', 'event' => 'start_processing' },
                 AuditLog.find(log.id).payload)
  end

  def test_actor_optional_for_automatic_actions
    log = AuditLog.create!(resource: @issue, action: 'issue.transition_auto', actor: nil)

    assert_nil log.actor_id
    assert_predicate log, :persisted?
  end
end

# frozen_string_literal: true

require_relative '../rails_helper'

class AuditTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: 'admin@modulotech.fr', name: 'Admin')
    @issue = Issue.create!(project_path: 'group/proj', issue_iid: 7, status: 'pending')
  end

  def test_record_persists_resource_and_actor
    log = Audit.record!(
      resource: @issue, action: 'issue.reset_manual', actor: @user,
      payload: { previous_state: 'error' }
    )

    assert_predicate log, :persisted?
    assert_equal @issue.id, log.resource_id
    assert_equal @user.id, log.actor_id
  end

  def test_record_round_trips_payload
    log = Audit.record!(
      resource: @issue, action: 'issue.reset_manual', actor: @user,
      payload: { previous_state: 'error' }
    )

    assert_equal({ 'previous_state' => 'error' }, log.payload)
  end

  def test_record_accepts_nil_actor
    log = Audit.record!(resource: @issue, action: 'issue.transition_auto')

    assert_predicate log, :persisted?
    assert_nil log.actor_id
    assert_equal({}, log.payload)
  end

  def test_record_swallows_invalid_action_and_returns_nil
    # `AuditLog.where(action: ...)` rather than `AuditLog.count` so the
    # assertion is robust against legacy Minitest::Test tests that
    # don't go through the ActiveSupport::TestCase teardown hook —
    # they can leak audit_log rows with valid action names that aren't
    # ours to clean up before our test runs.
    swallowed = capture_logger_warn do
      assert_nil Audit.record!(resource: @issue, action: 'not.a.real.action')
    end

    assert_match(/failed to record not\.a\.real\.action/, swallowed)
    assert_equal 0, AuditLog.where(action: 'not.a.real.action').count
  end

  private

  def capture_logger_warn
    io = StringIO.new
    original = Rails.logger
    Rails.logger = Logger.new(io)
    yield
    io.string
  ensure
    Rails.logger = original
  end
end

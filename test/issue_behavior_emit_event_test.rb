# frozen_string_literal: true

require_relative 'test_helper'

class IssueBehaviorEmitEventTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
  end

  def test_transition_creates_activity_event_row
    issue = create_issue
    issue.start_processing!

    events = ActivityEvent.where(issue_id: issue.id).where(kind: 'transition').all

    assert_equal 1, events.size
  end

  def test_transition_payload_records_from_to_event
    issue = create_issue
    issue.start_processing!

    payload = ActivityEvent.where(issue_id: issue.id).first.payload

    assert_equal({ 'from' => 'pending', 'to' => 'cloning', 'event' => 'start_processing' }, payload)
  end

  def test_chain_of_transitions_persists_all
    issue = create_issue
    advance_to(issue, 'checking_pipeline')

    count = ActivityEvent.where(issue_id: issue.id).where(kind: 'transition').count

    assert_equal 7, count
  end

  def test_invalid_transition_does_not_create_row
    issue = create_issue
    issue.impl_complete! # not allowed from :pending, returns false silently

    assert_equal 0, ActivityEvent.where(issue_id: issue.id).count
  end
end

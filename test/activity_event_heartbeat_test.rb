# frozen_string_literal: true

require_relative 'test_helper'

# The heartbeat kind's contract (Autodev #50). A heartbeat row exists for one
# reader — Issue.without_activity_since, which bounds how long a live worker may
# stay silent before dispatch_dormant_audit repositions its row. It is machinery,
# not activity anyone asked to see, so it must stay out of every rendering path
# while remaining visible to the staleness query.
class ActivityEventHeartbeatTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
    @issue = create_issue(status: 'implementing', created_at: 4.hours.ago)
  end

  def heartbeat(created_at: Time.now.utc)
    ActivityEvent.create!(issue_id: @issue.id, kind: 'heartbeat', level: 'info',
                          payload_json: JSON.generate(event: 'dc_call', label: '-p'),
                          created_at: created_at)
  end

  def test_heartbeat_is_an_accepted_kind
    assert_includes ActivityEvent::KINDS, 'heartbeat'
  end

  def test_user_visible_excludes_heartbeats
    heartbeat
    transition = ActivityEvent.create!(issue_id: @issue.id, kind: 'transition',
                                       level: 'info', payload_json: '{}')

    assert_equal [transition.id], ActivityEvent.user_visible.pluck(:id)
  end

  # A heartbeat carries an issue_id, so the NULL-issue_id guard does not cover
  # it: without an explicit kind check, /stream would emit one Turbo Stream
  # frame per danger-claude call.
  def test_heartbeat_is_not_broadcast_to_the_event_bus
    published = []
    Web::EventBus.stub(:publish, ->(event) { published << event }) do
      heartbeat
      ActivityEvent.create!(issue_id: @issue.id, kind: 'transition', payload_json: '{}')
    end

    assert_equal %w[transition], published.map(&:kind)
  end

  # The load-bearing assertion: this is why the row is written at all. A row
  # whose only activity is a heartbeat inside the window is NOT stale.
  def test_a_heartbeat_counts_as_activity_for_the_staleness_query
    heartbeat(created_at: 10.minutes.ago)

    stale = Issue.where(status: 'implementing').without_activity_since(2.hours.ago)

    assert_empty stale.pluck(:id)
  end

  def test_an_old_heartbeat_does_not_hide_a_stale_row
    heartbeat(created_at: 4.hours.ago)

    stale = Issue.where(status: 'implementing').without_activity_since(2.hours.ago)

    assert_equal [@issue.id], stale.pluck(:id)
  end
end

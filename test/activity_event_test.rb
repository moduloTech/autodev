# frozen_string_literal: true

require_relative 'test_helper'

# Round-trip + payload semantics for the AR ActivityEvent model.
# Migration concerns moved to db/migrate/*; this test just verifies the
# model behaviour AR consumers depend on.
class ActivityEventTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
  end

  def test_table_created_by_migration
    assert_includes ActiveRecord::Base.connection.tables, 'activity_events'
  end

  def test_indexes_created
    indexes = ActiveRecord::Base.connection.indexes('activity_events').map(&:name)

    assert_includes indexes, 'idx_ae_issue'
    assert_includes indexes, 'idx_ae_kind'
  end

  def test_create_and_read_round_trip
    issue = create_issue
    payload = JSON.generate(from: 'pending', to: 'cloning', event: 'start_processing')
    event = ActivityEvent.create!(issue_id: issue.id, kind: 'transition', level: 'info', payload_json: payload)
    reloaded = ActivityEvent.find(event.id)

    assert_equal 'transition', reloaded.kind
    assert_equal 'info', reloaded.level
    assert_equal({ 'from' => 'pending', 'to' => 'cloning', 'event' => 'start_processing' }, reloaded.payload)
  end

  def test_payload_setter_serializes_to_json
    issue = create_issue
    event = ActivityEvent.new(issue_id: issue.id, kind: 'danger_claude')
    event.payload = { key: 'impl_complete', vars: { branch: 'feat/x' } }
    event.save!

    reloaded = ActivityEvent.find(event.id)

    assert_equal({ 'key' => 'impl_complete', 'vars' => { 'branch' => 'feat/x' } }, reloaded.payload)
  end

  def test_payload_returns_empty_hash_when_blank
    issue = create_issue
    event = ActivityEvent.create!(issue_id: issue.id, kind: 'poller')

    assert_equal({}, event.payload)
  end

  def test_payload_returns_empty_hash_on_invalid_json
    issue = create_issue
    ActiveRecord::Base.connection.execute(
      'INSERT INTO activity_events (issue_id, kind, level, payload_json) ' \
      "VALUES (#{issue.id}, 'error', 'error', 'not-json')"
    )
    event = ActivityEvent.last

    assert_equal({}, event.payload)
  end

  def test_default_level_is_info
    issue = create_issue
    event = ActivityEvent.create!(issue_id: issue.id, kind: 'poller')

    assert_equal 'info', ActivityEvent.find(event.id).level
  end

  def test_created_at_is_set_by_default
    issue = create_issue
    event = ActivityEvent.create!(issue_id: issue.id, kind: 'poller')

    refute_nil ActivityEvent.find(event.id).created_at
  end

  # System events (issue_id nil — poller heartbeats, cycle-error markers) feed
  # the health surface, not the per-issue SSE feed, so they are not broadcast.
  def test_system_event_is_not_broadcast_to_event_bus
    issue = create_issue
    published = []
    Web::EventBus.stub(:publish, ->(event) { published << event }) do
      ActivityEvent.create!(issue_id: nil, kind: 'poller', payload_json: '{}')
      ActivityEvent.create!(issue_id: issue.id, kind: 'transition', payload_json: '{}')
    end

    assert_equal [issue.id], published.map(&:issue_id)
  end

  # `user_visible` is the one definition of "a row somebody asked to see"
  # (Autodev #57). It used to hide `heartbeat` alone while the dashboard
  # sparkline carried its own three-kind list — two definitions of the same
  # notion, and `usage` had already fallen through the gap. It now hides every
  # machinery kind, which is also exactly the set the retention purge deletes.
  def test_user_visible_admits_the_business_kinds_and_hides_the_machinery_ones
    issue = create_issue
    ActivityEvent::KINDS.each { |kind| ActivityEvent.create!(issue_id: issue.id, kind: kind) }

    assert_equal (ActivityEvent::KINDS - ActivityEvent::MACHINERY_KINDS).sort,
                 ActivityEvent.user_visible.pluck(:kind).sort
  end

  def test_machinery_kinds_are_all_declared_kinds
    assert_empty ActivityEvent::MACHINERY_KINDS - ActivityEvent::KINDS
  end
end

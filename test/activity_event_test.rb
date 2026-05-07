# frozen_string_literal: true

require_relative 'test_helper'

class ActivityEventTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
  end

  def test_table_created_by_migration
    assert Database.db.table_exists?(:activity_events)
  end

  def test_indexes_created
    indexes = Database.db.indexes(:activity_events)

    assert_includes indexes.keys, :idx_ae_issue
    assert_includes indexes.keys, :idx_ae_kind
  end

  def test_create_and_read_round_trip
    issue = create_issue
    payload = JSON.generate(from: 'pending', to: 'cloning', event: 'start_processing')
    event = ActivityEvent.create(issue_id: issue.id, kind: 'transition', level: 'info', payload_json: payload)
    reloaded = ActivityEvent[event.id]

    assert_equal 'transition', reloaded.kind
    assert_equal 'info', reloaded.level
    assert_equal({ 'from' => 'pending', 'to' => 'cloning', 'event' => 'start_processing' }, reloaded.payload)
  end

  def test_payload_setter_serializes_to_json
    issue = create_issue
    event = ActivityEvent.new(issue_id: issue.id, kind: 'danger_claude')
    event.payload = { key: 'impl_complete', vars: { branch: 'feat/x' } }
    event.save_changes

    reloaded = ActivityEvent[event.id]

    assert_equal({ 'key' => 'impl_complete', 'vars' => { 'branch' => 'feat/x' } }, reloaded.payload)
  end

  def test_payload_returns_empty_hash_when_blank
    issue = create_issue
    event = ActivityEvent.create(issue_id: issue.id, kind: 'poller')

    assert_equal({}, event.payload)
  end

  def test_payload_returns_empty_hash_on_invalid_json
    issue = create_issue
    Database.db[:activity_events].insert(
      issue_id: issue.id, kind: 'error', level: 'error', payload_json: 'not-json'
    )
    event = ActivityEvent.last

    assert_equal({}, event.payload)
  end

  def test_default_level_is_info
    issue = create_issue
    event = ActivityEvent.create(issue_id: issue.id, kind: 'poller')

    assert_equal 'info', ActivityEvent[event.id].level
  end

  def test_created_at_is_set_by_default
    issue = create_issue
    event = ActivityEvent.create(issue_id: issue.id, kind: 'poller')

    refute_nil ActivityEvent[event.id].created_at
  end

  def test_migration_is_idempotent
    Database::Migration.create_activity_events!(Database.db)
    Database::Migration.create_activity_events!(Database.db)

    assert Database.db.table_exists?(:activity_events)
  end
end

# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'web_test_helper'

class WebSseTest < Minitest::Test
  include Rack::Test::Methods
  include DatabaseTestHelper
  include WebServerTestSetup
  include Web::Helpers

  # Stand-in for the `settings` helper Sinatra normally injects.
  Settings = Struct.new(:app_config)

  def settings
    Settings.new({})
  end

  def test_format_sse_emits_turbo_stream_for_event_row
    issue = create_issue
    event = ActivityEvent.create(issue_id: issue.id, kind: 'danger_claude',
                                 payload: { key: 'cloning', message: 'Clone' })

    frame = format_sse(event.values)

    assert_includes frame, %(target="events_#{issue.id}")
    assert_includes frame, 'action="prepend"'
  end

  def test_format_sse_transition_also_replaces_status_badge
    issue = create_issue
    event = ActivityEvent.create(issue_id: issue.id, kind: 'transition', payload: { from: 'a', to: 'b', event: 'go' })

    frame = format_sse(event.values)

    assert_includes frame, %(target="status_#{issue.id}")
    assert_includes frame, 'action="replace"'
  end

  def test_format_sse_non_transition_does_not_emit_status_stream
    issue = create_issue
    event = ActivityEvent.create(issue_id: issue.id, kind: 'poller')

    frame = format_sse(event.values)

    refute_includes frame, %(target="status_)
  end

  def test_format_sse_frame_terminator
    issue = create_issue
    event = ActivityEvent.create(issue_id: issue.id, kind: 'poller')

    assert frame = format_sse(event.values)
    assert frame.end_with?("\n\n")
  end

  def test_activity_event_after_create_publishes_to_event_bus
    Web::EventBus.reset!
    queue = Web::EventBus.subscribe
    issue = create_issue
    ActivityEvent.create(issue_id: issue.id, kind: 'poller')
    Web::EventBus.unsubscribe(queue)

    refute_predicate queue, :empty?
  end
end

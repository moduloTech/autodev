# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/discussion_snapshot'

# Instrumentation for the suspected race between mr-review and the next
# `fetch_unresolved_discussions` poll. The module is intentionally
# defensive — API failures, missing methods, malformed payloads must
# never break the workflow it's instrumenting — so most tests focus on
# correct payload shape under normal input plus graceful degradation.
class DiscussionSnapshotTest < Minitest::Test
  include DatabaseTestHelper

  FakeAuthor = Struct.new(:username)
  FakeNote = Struct.new(:author, :resolvable, :resolved, :created_at, :position)
  FakeDiscussion = Struct.new(:id, :notes)

  class StubClient
    def initialize(discussions)
      @discussions = discussions
    end

    def merge_request_discussions(_project_path, _mr_iid, **_opts)
      Paginated.new(@discussions)
    end

    Paginated = Struct.new(:list) { def auto_paginate = list }
  end

  def setup
    setup_database
    @logger = StubLogger.new
    @issue = create_issue(mr_iid: 99)
  end

  def test_payload_counts_unresolved_vs_total
    client = StubClient.new([
                              resolvable_discussion('a', resolved: false),
                              resolvable_discussion('b', resolved: true),
                              resolvable_discussion('c', resolved: false)
                            ])

    payload = capture(client, :post_mr_review)

    assert_equal 3, payload[:total]
    assert_equal 2, payload[:unresolved]
  end

  def test_payload_summarizes_each_discussion
    client = StubClient.new([resolvable_discussion('664b9d1bdeadbeef', resolved: false,
                                                                       author: 'ciappa_m', path: 'foo.rb', line: 42)])

    payload = capture(client, :pre_fix_dispatch)
    item = payload[:discussions].first

    assert_equal '664b9d1b', item[:id]
    assert_equal 'ciappa_m', item[:author]
    assert_equal 'foo.rb:42', item[:position]
  end

  def test_position_str_handles_general_comments
    client = StubClient.new([FakeDiscussion.new('z', [FakeNote.new(FakeAuthor.new('bot'), true, false,
                                                                   '2026-05-28T17:03:00Z', nil)])])

    payload = capture(client, :pre_mr_fix)

    assert_equal 'general', payload[:discussions].first[:position]
  end

  def test_position_str_marks_outdated_when_new_line_missing
    pos = { 'new_path' => 'foo.rb', 'old_path' => 'foo.rb', 'new_line' => nil, 'old_line' => nil }
    client = StubClient.new([FakeDiscussion.new('z', [FakeNote.new(FakeAuthor.new('bot'), true, false,
                                                                   '2026-05-28T17:03:00Z', pos)])])

    payload = capture(client, :pre_mr_fix)

    assert_equal 'foo.rb:outdated', payload[:discussions].first[:position]
  end

  def test_persist_writes_activity_event_with_snapshot_kind
    client = StubClient.new([resolvable_discussion('a', resolved: false)])

    capture(client, :post_mr_review)
    events = Database.db[:activity_events].where(issue_id: @issue.id, kind: 'discussions_snapshot').all

    assert_equal 1, events.size
    assert_equal 'post_mr_review', JSON.parse(events.first[:payload_json])['context']
  end

  def test_api_failure_returns_empty_snapshot_not_nil
    failing_client = Object.new
    failing_client.define_singleton_method(:merge_request_discussions) { |*_, **_| raise 'boom' }

    payload = capture(failing_client, :post_mr_review)

    assert_equal 0, payload[:total]
    assert_equal 0, payload[:unresolved]
  end

  private

  def capture(client, context)
    DiscussionSnapshot.capture(context: context, client: client, project_path: 'g/p',
                               mr_iid: 99, logger: @logger, issue: @issue)
  end

  def resolvable_discussion(id, resolved:, author: 'bot', path: 'a.rb', line: 1)
    pos = { 'new_path' => path, 'old_path' => path, 'new_line' => line, 'old_line' => line }
    note = FakeNote.new(FakeAuthor.new(author), true, resolved, '2026-05-28T17:03:00Z', pos)
    FakeDiscussion.new(id, [note])
  end
end

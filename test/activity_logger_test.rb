# frozen_string_literal: true

require_relative 'test_helper'

require 'autodev/label_manager'
require 'autodev/activity_logger'

class ActivityLoggerTest < Minitest::Test
  include DatabaseTestHelper

  FakeNote = Struct.new(:id, :body)

  class FakeClient
    attr_reader :created, :edited

    def initialize(fail: false)
      @fail = fail
      @created = []
      @edited = []
      @next_id = 100
    end

    def create_issue_note(project, iid, body)
      raise StandardError, 'gitlab down' if @fail

      @created << [project, iid, body]
      FakeNote.new(@next_id += 1, body)
    end

    def issue_note(_project, _iid, _id)
      FakeNote.new(0, 'header line')
    end

    def edit_issue_note(project, iid, id, body)
      @edited << [project, iid, id, body]
      FakeNote.new(id, body)
    end
  end

  def setup
    setup_database
  end

  def test_post_creates_one_activity_event
    issue = create_issue
    ctx = ActivityLogger::Ctx.new(FakeClient.new, 'g/p', nil)

    ActivityLogger.post(ctx, issue, :started)

    assert_equal 1, ActivityEvent.where(issue_id: issue.id).count
  end

  def test_post_writes_kind_level_and_key
    issue = create_issue
    ctx = ActivityLogger::Ctx.new(FakeClient.new, 'g/p', nil)

    ActivityLogger.post(ctx, issue, :started)
    event = ActivityEvent.where(issue_id: issue.id).first

    assert_equal %w[danger_claude info started], [event.kind, event.level, event.payload['key']]
  end

  def test_post_persists_message_in_payload
    issue = create_issue
    ctx = ActivityLogger::Ctx.new(FakeClient.new, 'g/p', nil)

    ActivityLogger.post(ctx, issue, :cloning, detail: 'feat/x')

    payload = ActivityEvent.where(issue_id: issue.id).first.payload

    assert_includes payload['message'], 'Clonage'
    assert_includes payload['message'], 'feat/x'
    assert_equal({ 'detail' => 'feat/x' }, payload['vars'])
  end

  def test_post_still_persists_when_gitlab_call_fails
    issue = create_issue
    ctx = ActivityLogger::Ctx.new(FakeClient.new(fail: true), 'g/p', nil)

    ActivityLogger.post(ctx, issue, :started)

    assert_equal 1, ActivityEvent.where(issue_id: issue.id).count
  end

  def test_post_does_not_break_when_db_write_fails
    issue = create_issue
    ctx = ActivityLogger::Ctx.new(FakeClient.new, 'g/p', nil)
    Object.send(:remove_const, :ActivityEvent)
    begin
      ActivityLogger.post(ctx, issue, :started)
    ensure
      Database.build_activity_event_model!
    end

    assert_equal 1, ctx.client.created.size
  end
end

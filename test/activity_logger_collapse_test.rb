# frozen_string_literal: true

require_relative 'test_helper'

require 'autodev/activity_logger'

# `replace_pattern:` has always meant "this entry supersedes its previous
# occurrence" — but only for the GitLab note. `persist_event!` ran before the
# note upsert and always INSERTed, so a ticket polled every cycle in
# `checking_pipeline` grew one `activity_events` row per poll: 477 827 of the
# 898 424 rows in production carried the `pipeline_checking` key, 29 773 of them
# on issue #15894 alone (Autodev #53).
#
# The rule now applies to both sinks: a replaced note line has a replaced row.
class ActivityLoggerCollapseTest < Minitest::Test
  include DatabaseTestHelper

  FakeNote = Struct.new(:id, :body)

  # Minimal note sink. `issue_note` echoes whatever was last written so
  # `replace_or_append` operates on a realistic body.
  class FakeClient
    attr_reader :edited

    def initialize
      @body = 'header line'
      @edited = []
    end

    def create_issue_note(_project, _iid, body)
      @body = body
      FakeNote.new(42, body)
    end

    def issue_note(_project, _iid, _id) = FakeNote.new(42, @body)

    def edit_issue_note(project, iid, id, body)
      @body = body
      @edited << [project, iid, id, body]
      FakeNote.new(id, body)
    end
  end

  POLL_PATTERN = /— :mag:.*(?:pipeline|statut du pipeline)/

  def setup
    setup_database
    @ctx = ActivityLogger::Ctx.new(FakeClient.new, 'g/p', nil)
  end

  def poll(issue, since: '08-01 10:00')
    ActivityLogger.post(@ctx, issue, :pipeline_checking, since: since, replace_pattern: POLL_PATTERN)
  end

  def events_for(issue) = ActivityEvent.where(issue_id: issue.id).to_a

  def test_a_replaced_entry_keeps_a_single_row
    issue = create_issue
    3.times { poll(issue) }

    assert_equal 1, events_for(issue).size
  end

  def test_the_surviving_row_carries_the_newest_payload
    issue = create_issue
    poll(issue, since: '08-01 10:00')
    poll(issue, since: '08-02 11:00')

    assert_includes events_for(issue).first.payload['message'], '08-02 11:00'
  end

  def test_the_surviving_row_records_the_last_occurrence
    issue = create_issue
    poll(issue)
    ActivityEvent.where(issue_id: issue.id).update_all(created_at: 3.hours.ago)

    poll(issue)

    assert_operator events_for(issue).first.created_at, :>, 1.hour.ago
  end

  def test_an_entry_without_a_replace_pattern_still_appends
    issue = create_issue
    2.times { ActivityLogger.post(@ctx, issue, :started) }

    assert_equal 2, events_for(issue).size
  end

  def test_two_collapsible_keys_do_not_collapse_into_each_other
    issue = create_issue
    poll(issue)
    ActivityLogger.post(@ctx, issue, :pipeline_infra, detail: 'deploy', replace_pattern: /:warning:/)

    assert_equal %w[pipeline_checking pipeline_infra],
                 events_for(issue).map { |e| e.payload['key'] }.sort
  end

  def test_two_issues_do_not_collapse_into_each_other
    first = create_issue
    second = create_issue
    poll(first)
    poll(second)

    assert_equal [1, 1], [events_for(first).size, events_for(second).size]
  end

  # `update_columns` skips `after_create_commit`, so a re-occurrence no longer
  # pushes a Turbo frame — one per poll per watched row used to reach /stream.
  def test_a_superseded_row_publishes_nothing_to_the_event_bus
    issue = create_issue
    poll(issue)
    published = []
    Web::EventBus.stub(:publish, ->(event) { published << event }) { poll(issue) }

    assert_empty published
  end

  def test_the_note_is_still_updated_when_the_db_write_fails
    issue = create_issue
    poll(issue)
    ActivityEvent.stub(:where, ->(*_) { raise StandardError, 'simulated DB failure' }) do
      poll(issue)
    end

    refute_empty @ctx.client.edited
  end
end

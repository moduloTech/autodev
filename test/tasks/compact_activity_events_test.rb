# frozen_string_literal: true

require_relative '../test_helper'

# Retroactive application of the per-poll collapse (Autodev #53): keep the most
# recent occurrence of a collapsible activity key per issue, delete the
# superseded ones. Production had 477 827 such rows out of 898 424, in a 264 MB
# file, 29 773 of them on issue #15894 alone.
#
# NEVER run against ~/.autodev/. These tests exercise the in-memory test
# database only; the production purge is a manual operation, documented in
# docs/superpowers/specs/2026-08-11-bound-pipeline-watch-design.md.
class CompactActivityEventsTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
    @out = StringIO.new
  end

  def compact(apply: false, vacuum: false)
    Autodev::ActivityEventCompaction.new(apply: apply, vacuum: vacuum, out: @out).run
  end

  def poll_event(issue, key: 'pipeline_checking', at: Time.current)
    ActivityEvent.create!(issue_id: issue.id, kind: 'danger_claude', level: 'info',
                          payload_json: JSON.generate(key: key, vars: {}, message: 'x'))
                 .tap { |event| event.update_columns(created_at: at) }
  end

  def test_the_default_run_deletes_nothing
    issue = create_issue
    3.times { |i| poll_event(issue, at: i.hours.ago) }

    compact

    assert_equal 3, ActivityEvent.count
  end

  def test_the_default_run_reports_what_it_would_delete
    issue = create_issue
    3.times { |i| poll_event(issue, at: i.hours.ago) }

    compact

    assert_match(/pipeline_checking.*3 .*2/, @out.string)
  end

  def test_apply_keeps_only_the_newest_row_per_issue_and_key
    issue = create_issue
    poll_event(issue, at: 5.hours.ago)
    poll_event(issue, at: 2.hours.ago)
    newest = poll_event(issue, at: 1.minute.ago)

    compact(apply: true)

    assert_equal [newest.id], ActivityEvent.pluck(:id)
  end

  def test_apply_keeps_one_row_per_key
    issue = create_issue
    2.times { poll_event(issue, key: 'pipeline_checking') }
    2.times { poll_event(issue, key: 'pipeline_infra') }

    compact(apply: true)

    assert_equal %w[pipeline_checking pipeline_infra],
                 ActivityEvent.all.map { |event| event.payload['key'] }.sort
  end

  def test_apply_keeps_one_row_per_issue
    first = create_issue
    second = create_issue
    2.times { poll_event(first) }
    2.times { poll_event(second) }

    compact(apply: true)

    assert_equal [first.id, second.id].sort, ActivityEvent.pluck(:issue_id).sort
  end

  # Everything that is not a collapsible occurrence must survive untouched:
  # transitions carry the row's history, heartbeats bound a live worker's
  # silence (Autodev #50), and the system rows feed HealthReport.
  def test_other_rows_are_untouched
    issue = create_issue
    2.times { poll_event(issue) }
    ActivityEvent.create!(issue_id: issue.id, kind: 'transition', level: 'info', payload_json: '{}')
    ActivityEvent.create!(issue_id: issue.id, kind: 'heartbeat', level: 'info', payload_json: '{}')
    ActivityEvent.create!(issue_id: nil, kind: 'poller', level: 'info', payload_json: '{}')
    2.times { poll_event(issue, key: 'mr_created') }

    compact(apply: true)

    assert_equal %w[danger_claude danger_claude danger_claude heartbeat poller transition],
                 ActivityEvent.pluck(:kind).sort
  end

  def test_running_twice_deletes_nothing_the_second_time
    issue = create_issue
    3.times { poll_event(issue) }
    compact(apply: true)
    remaining = ActivityEvent.pluck(:id)

    compact(apply: true)

    assert_equal remaining, ActivityEvent.pluck(:id)
  end

  def test_an_empty_table_is_a_no_op
    compact(apply: true)

    assert_equal 0, ActivityEvent.count
  end
end

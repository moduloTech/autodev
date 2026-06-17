# frozen_string_literal: true

require_relative 'autodev_test_helper'

# Regression coverage for Web::Helpers#weekly_activity_counts — the data behind
# the dashboard "Activité de la semaine" sparkline. In production it silently
# returned [0,0,0,0,0,0,0] despite thousands of events, because AR stored
# `created_at` as "2026-06-11 11:13:03 UTC" and SQLite's `date()` returns NULL
# on that format, collapsing every row under a NULL bucket.
class WeeklyActivityCountsTest < Minitest::Test
  include DatabaseTestHelper

  # Minimal host for the Web::Helpers mixin. With no `current_user` method,
  # `admin_or_no_session?` is true, so the dataset is `ActivityEvent.all`.
  class Host
    include ::Web::Helpers
  end

  def setup
    setup_database
    @issue = create_issue
    @helper = Host.new
  end

  # Raw insert so the test pins `created_at` exactly, bypassing AR's timestamp
  # + timezone machinery — the grouping logic under test is pure SQL.
  def insert_event(created_at)
    ActiveRecord::Base.connection.execute(
      'INSERT INTO activity_events (issue_id, kind, level, payload_json, created_at) ' \
      "VALUES (#{@issue.id}, 'poller', 'info', '{}', '#{created_at}')"
    )
  end

  def test_returns_seven_zeros_when_no_events
    assert_equal [0, 0, 0, 0, 0, 0, 0], @helper.weekly_activity_counts
  end

  def test_buckets_oldest_first_with_today_rightmost
    2.times { insert_event("#{Date.today} 12:00:00") }
    insert_event("#{Date.today - 3} 12:00:00")

    counts = @helper.weekly_activity_counts

    assert_equal 2, counts.last, 'today is the rightmost bucket'
    assert_equal 1, counts[3],   '3 days ago lands at index 6-3'
    assert_equal 3, counts.sum,  'only the 3 in-window events are counted'
  end

  def test_events_older_than_the_window_are_excluded
    insert_event("#{Date.today - 10} 12:00:00")

    assert_equal [0, 0, 0, 0, 0, 0, 0], @helper.weekly_activity_counts
  end

  # The actual prod bug: a " UTC"-suffixed timestamp must still be counted.
  # date('… UTC') is NULL in SQLite; the helper strips the suffix first.
  def test_utc_suffixed_rows_are_still_counted
    insert_event("#{Date.today} 11:13:03 UTC")

    assert_equal 1, @helper.weekly_activity_counts.last,
                 'a " UTC"-suffixed row must still land in today\'s bucket'
  end
end

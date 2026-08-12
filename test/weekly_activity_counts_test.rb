# frozen_string_literal: true

require_relative 'autodev_test_helper'

# Regression coverage for Web::Helpers#weekly_activity_counts — the data behind
# the dashboard "Activité de la semaine" sparkline. In production it silently
# returned [0,0,0,0,0,0,0] despite thousands of events, because AR stored
# `created_at` as "2026-06-11 11:13:03 UTC" and SQLite's `date()` returns NULL
# on that format, collapsing every row under a NULL bucket. The helper now
# range-counts each local day instead of relying on date(), and buckets in the
# configured display zone.
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
  # + timezone machinery — the grouping logic under test is pure SQL. Defaults
  # to a work kind ('transition'); 'poller'/'error' are system kinds excluded
  # from the sparkline.
  def insert_event(created_at, kind: 'transition')
    ActiveRecord::Base.connection.execute(
      'INSERT INTO activity_events (issue_id, kind, level, payload_json, created_at) ' \
      "VALUES (#{@issue.id}, '#{kind}', 'info', '{}', '#{created_at}')"
    )
  end

  def test_returns_seven_zeros_when_no_events
    assert_equal [0, 0, 0, 0, 0, 0, 0], @helper.weekly_activity_counts
  end

  # Default zone in the test env is UTC, so the inserted noon-UTC timestamps
  # bucket on the UTC calendar day matching Time.zone.today.
  def test_buckets_oldest_first_with_today_rightmost
    2.times { insert_event("#{Time.zone.today} 12:00:00") }
    insert_event("#{Time.zone.today - 3} 12:00:00")

    counts = @helper.weekly_activity_counts

    assert_equal 2, counts.last, 'today is the rightmost bucket'
    assert_equal 1, counts[3],   '3 days ago lands at index 6-3'
    assert_equal 3, counts.sum,  'only the 3 in-window events are counted'
  end

  def test_events_older_than_the_window_are_excluded
    insert_event("#{Time.zone.today - 10} 12:00:00")

    assert_equal [0, 0, 0, 0, 0, 0, 0], @helper.weekly_activity_counts
  end

  # The actual prod bug: a " UTC"-suffixed timestamp must still be counted.
  # date('… UTC') is NULL in SQLite; the range bucketing sidesteps date().
  def test_utc_suffixed_rows_are_still_counted
    insert_event("#{Time.zone.today} 11:13:03 UTC")

    assert_equal 1, @helper.weekly_activity_counts.last,
                 'a " UTC"-suffixed row must still land in today\'s bucket'
  end

  # System kinds (poller heartbeats, cycle-error markers) must not inflate the
  # sparkline — only real work (transition/danger_claude) counts.
  def test_excludes_system_kinds
    insert_event("#{Time.zone.today} 12:00:00", kind: 'transition')
    insert_event("#{Time.zone.today} 12:00:00", kind: 'poller')
    insert_event("#{Time.zone.today} 12:00:00", kind: 'error')

    assert_equal 1, @helper.weekly_activity_counts.last,
                 'only the work event counts; poller/error are excluded'
  end

  # Liveness markers (Autodev #50) are written once per danger-claude call, so
  # counting them would make the sparkline measure worker chatter instead of
  # work done.
  def test_heartbeat_events_are_excluded
    insert_event("#{Time.zone.today} 12:00:00", kind: 'heartbeat')
    insert_event("#{Time.zone.today} 12:00:00", kind: 'transition')

    assert_equal 1, @helper.weekly_activity_counts.sum
  end

  # The Claude-quota verdict (Autodev #46) is one row per poll cycle — 720/day
  # in production. It slipped past the hardcoded three-kind list this helper
  # used to carry, and once Autodev #53 collapsed the per-poll danger_claude row
  # it became the *majority* of the bar: 382 usage rows against 30 danger_claude
  # on 12/08/2026. Routing through `user_visible` (Autodev #57) is what fixes it.
  def test_usage_events_are_excluded
    insert_event("#{Time.zone.today} 12:00:00", kind: 'usage')
    insert_event("#{Time.zone.today} 12:00:00", kind: 'transition')

    assert_equal 1, @helper.weekly_activity_counts.sum
  end

  # Constat 3 of Autodev #57: the sparkline and `ActivityEvent.user_visible` had
  # two competing definitions of "masqué", free to diverge at the next kind
  # added — which is precisely how `usage` slipped in. One definition now, and
  # this pins the sparkline to it rather than to a copy of its contents.
  def test_counts_exactly_what_user_visible_admits
    ActivityEvent::KINDS.each { |kind| insert_event("#{Time.zone.today} 12:00:00", kind: kind) }

    assert_equal ActivityEvent.user_visible.count, @helper.weekly_activity_counts.sum
  end

  # An event at 00:30 Europe/Paris is stored ~22:30/23:30 the previous UTC day.
  # UTC-day bucketing would file it under yesterday; the zone-aware helper must
  # place it in today's (rightmost) bar.
  def test_buckets_by_local_day_not_utc_day
    paris = ActiveSupport::TimeZone['Europe/Paris']
    utc_string = paris.now.change(hour: 0, min: 30, sec: 0).utc.strftime('%F %T')
    insert_event(utc_string)

    @helper.stub(:app_config, { 'web' => { 'timezone' => 'Europe/Paris' } }) do
      counts = @helper.weekly_activity_counts

      assert_equal 1, counts.last,  'today (Paris) is the rightmost bucket'
      assert_equal 0, counts[5],    'must not leak into yesterday'
    end
  end
end

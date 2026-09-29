# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/rate_limit_detector'

# RateLimitDetector.parse_reset_time on a reset that names its date — Autodev
# #127. A weekly limit more than a day from its reset reads "resets Oct 1, 3am
# (UTC)"; before #127 the hour-only pattern did not match it at all, so the
# pause fell back to the one-hour default until the 1st.
class RateLimitResetDateTest < Minitest::Test
  NOW = Time.utc(2026, 9, 28, 14, 0, 0)

  def test_a_dated_reset_reads_the_date
    reset = RateLimitDetector.parse_reset_time('resets Oct 1, 3am (UTC)', now: NOW)

    assert_equal Time.utc(2026, 10, 1, 3, 0, 0), reset
  end

  def test_a_dated_reset_with_minutes_reads_them
    reset = RateLimitDetector.parse_reset_time('resets Oct 12, 11:30pm (UTC)', now: NOW)

    assert_equal Time.utc(2026, 10, 12, 23, 30, 0), reset
  end

  # A December message naming January is next year's January.
  def test_a_dated_reset_rolls_over_the_year
    reset = RateLimitDetector.parse_reset_time('resets Jan 2, 3am (UTC)', now: Time.utc(2026, 12, 30, 10))

    assert_equal Time.utc(2027, 1, 2, 3, 0, 0), reset
  end

  # A date that has just passed (latency, clock skew) is this year's, not a
  # year's pause: wait_seconds floors it at 60s.
  def test_a_dated_reset_just_passed_stays_this_year
    now = Time.utc(2026, 10, 1, 3, 5)
    reset = RateLimitDetector.parse_reset_time('resets Oct 1, 3am (UTC)', now: now)

    assert_equal Time.utc(2026, 10, 1, 3, 0, 0), reset
  end

  def test_a_month_may_be_spelled_short_or_long
    %w[Oct October oct].each do |month|
      assert_equal Time.utc(2026, 10, 1, 3, 0, 0),
                   RateLimitDetector.parse_reset_time("resets #{month} 1, 3am (UTC)", now: NOW), month
    end
  end

  def test_an_unknown_month_reads_no_reset_rather_than_a_guess
    assert_nil RateLimitDetector.parse_reset_time('resets Foo 1, 3am (UTC)', now: NOW)
    assert_nil RateLimitDetector.parse_reset_time('resets Octopus 1, 3am (UTC)', now: NOW)
  end

  def test_an_impossible_day_reads_no_reset_rather_than_a_normalised_date
    assert_nil RateLimitDetector.parse_reset_time('resets Feb 30, 3am (UTC)', now: NOW)
  end

  def test_the_hour_only_form_is_unchanged
    assert_equal Time.utc(2026, 9, 28, 19, 0, 0), RateLimitDetector.parse_reset_time('resets 7pm (UTC)', now: NOW)
    assert_equal Time.utc(2026, 9, 29, 3, 0, 0), RateLimitDetector.parse_reset_time('resets 3am (UTC)', now: NOW)
  end

  # `now:` is the clock, not the machine's: a fixture far from today.
  def test_the_given_clock_is_the_one_read
    assert_equal Time.utc(2025, 6, 1, 3),
                 RateLimitDetector.parse_reset_time('resets Jun 1, 3am (UTC)', now: Time.utc(2025, 6, 1, 3, 5))
    assert_equal Time.utc(2030, 1, 2, 3),
                 RateLimitDetector.parse_reset_time('resets 3am (UTC)', now: Time.utc(2030, 1, 1, 12))
  end

  # The cut-off between "just passed" and "next year" is one day.
  def test_a_date_passed_by_less_than_a_day_stays_this_year_and_by_more_is_next_year
    wording = 'resets Oct 1, 3am (UTC)'

    assert_equal Time.utc(2026, 10, 1, 3), RateLimitDetector.parse_reset_time(wording, now: Time.utc(2026, 10, 2, 2))
    assert_equal Time.utc(2027, 10, 1, 3), RateLimitDetector.parse_reset_time(wording, now: Time.utc(2026, 10, 2, 4))
  end

  # Read just after New Year, "Dec 31" is last year's, not a year's pause.
  def test_a_date_just_passed_across_new_year_is_last_years
    reset = RateLimitDetector.parse_reset_time('resets Dec 31, 11pm (UTC)', now: Time.utc(2027, 1, 1, 0, 30))

    assert_equal Time.utc(2026, 12, 31, 23), reset
  end

  # An hour a 12-hour clock does not have reads as no reset — Time.utc would
  # raise, and a quota would take the failure path again.
  def test_an_impossible_time_reads_no_reset_rather_than_raising
    ['resets Oct 1, 13pm (UTC)', 'resets Oct 1, 3:75am (UTC)', 'resets 0am (UTC)'].each do |text|
      assert_nil RateLimitDetector.parse_reset_time(text, now: NOW), text
    end
  end
end

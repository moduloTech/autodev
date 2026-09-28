# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/rate_limit_detector'

# Regression: the original pattern (`/you've hit your limit|rate limit|usage limit/i`)
# missed claude-code's "You've hit your **session** limit" phrasing. When the API
# hit that variant, RateLimitDetector.check! silently returned, danger-claude
# exited non-zero, and the caller raised ImplementationError instead of
# RateLimitError — bypassing the rate-limit pause logic in
# {IssueProcessor,MrFixer,PipelineMonitor}::ErrorHandler. Observed on Powerpanne
# issues #15643/#15737/#15855/#15125/#16044 (2026-06-02): all marked as `error`
# with "session limit · resets HH:MMam (UTC)" in stdout when they should have
# paused and retried.
class RateLimitDetectorTest < Minitest::Test
  def test_session_limit_phrasing_triggers_rate_limit_error
    e = assert_raises(RateLimitError) do
      RateLimitDetector.check!("You've hit your session limit · resets 6:40pm (UTC)\n", '')
    end
    assert_match(/rate limit/i, e.message)
  end

  def test_usage_limit_phrasing_triggers_rate_limit_error
    assert_raises(RateLimitError) do
      RateLimitDetector.check!("You've hit your usage limit · resets 11am (UTC)\n", '')
    end
  end

  def test_plain_limit_phrasing_still_triggers
    assert_raises(RateLimitError) do
      RateLimitDetector.check!("You've hit your limit · resets 11:30am (UTC)\n", '')
    end
  end

  def test_unrelated_failure_does_not_trigger
    RateLimitDetector.check!("error: command failed\n", 'fatal: ambiguous argument')
    # No raise → pass.
  end

  def test_reset_time_parses_hour_and_minutes
    e = assert_raises(RateLimitError) do
      RateLimitDetector.check!("You've hit your session limit · resets 11:30am (UTC)\n", '')
    end
    assert_equal [11, 30], [e.reset_time.hour, e.reset_time.min]
  end

  def test_reset_time_handles_bare_hour
    e = assert_raises(RateLimitError) do
      RateLimitDetector.check!("You've hit your limit · resets 6pm (UTC)\n", '')
    end
    assert_equal 18, e.reset_time.hour
    assert_equal 0, e.reset_time.min
  end

  # --- Autodev #127: the weekly limit, and a reset that names a date --------
  #
  # Every wording below is verbatim from production (issues.error_message,
  # dc_stdout, activity_events) or from the Claude Code 2.1.283 binary. The
  # weekly one went unrecognised on 2026-09-24 and 2026-09-26: five rows took
  # the generic failure path, four of them with a public "echec" comment.
  SEEN_WORDINGS = [
    "You've hit your limit · resets 7pm (UTC)",
    "You've hit your session limit · resets 4:30am (UTC)",
    "You've hit your weekly limit · resets 3am (UTC)",
    "You've hit your weekly limit · resets Oct 1, 3am (UTC)",
    "You've hit your fast limit · resets 5pm (UTC)",
    "You've hit your monthly spend limit",
    'You’ve hit your weekly limit · resets Oct 1, 3am (UTC)'
  ].freeze

  NOW = Time.utc(2026, 9, 28, 14, 0, 0)

  def test_every_wording_seen_in_production_triggers
    SEEN_WORDINGS.each do |wording|
      assert_raises(RateLimitError, wording) { RateLimitDetector.check!("#{wording}\n", '') }
    end
  end

  # The probe's verbatim output since 2026-09-27: the mise noise follows the
  # message, which must not hide it.
  def test_the_weekly_wording_followed_by_mise_noise_triggers
    out = "You've hit your weekly limit · resets Oct 1, 3am (UTC)\n\n" \
          "mise ERROR Config files in ~/modulotech/.config/mise/config.toml are not trusted.\n"
    assert_raises(RateLimitError) { RateLimitDetector.check!(out, '') }
  end

  def test_a_limit_the_sentence_does_not_name_as_hit_does_not_trigger
    RateLimitDetector.check!("You've hit your stride, no limit in sight\n", '')
    RateLimitDetector.check!("Set the upload limit to 10MB\n", '')
  end

  # Two words at most between "your" and "limit": a sentence claude writes
  # about the code under work is not a quota.
  def test_a_three_word_qualifier_does_not_trigger
    RateLimitDetector.check!("You've hit your max open merge request limit\n", '')
  end

  def test_a_short_or_four_letter_month_reaches_the_pause
    now = Time.utc(2026, 8, 30)
    resets = %w[Sep Sept].map do |month|
      RateLimitDetector.check!("You've hit your weekly limit · resets #{month} 3, 3am (UTC)", '', now: now)
    rescue RateLimitError => e
      e.reset_time
    end

    assert_equal [Time.utc(2026, 9, 3, 3)] * 2, resets
  end

  # The date appears from 24h out, not before.
  def test_the_message_names_the_date_from_a_day_out
    reset = Time.utc(2026, 10, 1, 3)
    suffixes = [86_340, 86_400].map { |ahead| RateLimitDetector.reset_suffix(reset, reset - ahead) }

    assert_equal [' (resets 03:00 UTC)', ' (resets 2026-10-01 03:00 UTC)'], suffixes
  end

  # The pause A#144 should have taken: until the reset, not an hour.
  def test_the_weekly_reset_drives_the_pause
    e = assert_raises(RateLimitError) do
      RateLimitDetector.check!("You've hit your weekly limit · resets Oct 1, 3am (UTC)", '', now: NOW)
    end

    assert_equal Time.utc(2026, 10, 1, 3, 0, 0), e.reset_time
    assert_includes e.message, '2026-10-01 03:00 UTC'
  end

  def test_a_same_day_reset_keeps_the_short_message
    e = assert_raises(RateLimitError) do
      RateLimitDetector.check!("You've hit your session limit · resets 7pm (UTC)", '', now: NOW)
    end

    assert_includes e.message, '(resets 19:00 UTC)'
  end
end

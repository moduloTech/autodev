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
end

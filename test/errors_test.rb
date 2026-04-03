# frozen_string_literal: true

require_relative 'test_helper'

class ErrorsTest < Minitest::Test
  def test_error_hierarchy
    assert_kind_of AutodevError, ConfigError.new
    assert_kind_of AutodevError, GitError.new
    assert_kind_of AutodevError, ImplementationError.new
    assert_kind_of AutodevError, RateLimitError.new('msg')
  end

  def test_rate_limit_wait_seconds_with_future_reset
    reset = Time.now.utc + 600
    err = RateLimitError.new('rate limited', reset_time: reset)
    wait = err.wait_seconds

    assert_in_delta 600, wait, 5
  end

  def test_rate_limit_wait_seconds_without_reset_time
    err = RateLimitError.new('rate limited')

    assert_equal 3600, err.wait_seconds
  end

  def test_rate_limit_wait_seconds_minimum_60
    reset = Time.now.utc + 10 # only 10s away
    err = RateLimitError.new('rate limited', reset_time: reset)

    assert_equal 60, err.wait_seconds
  end

  def test_rate_limit_wait_seconds_past_reset_returns_minimum
    reset = Time.now.utc - 100 # already past
    err = RateLimitError.new('rate limited', reset_time: reset)

    assert_equal 60, err.wait_seconds
  end
end

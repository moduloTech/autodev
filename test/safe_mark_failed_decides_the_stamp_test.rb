# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'

# Autodev #103, item 3: `safe_mark_failed!` is the single funnel every
# `error` entry goes through, and it must take the stamp decision explicitly
# rather than leave the column as it found it — leaving it as found is what
# stranded a row with an unspent budget (no stamp ever written) and, in
# 15888's mirror case, what let a stamp from a previous life (2026-05-14)
# survive into this one and make the row selected on every cycle forever.
class SafeMarkFailedDecidesTheStampTest < Minitest::Test
  include DatabaseTestHelper

  # A minimal host: just enough of DangerClaudeRunner's contract for
  # safe_mark_failed! to run standalone.
  class Runner
    include DangerClaudeRunner
  end

  def setup = setup_database

  def runner = Runner.new

  def active_issue(overrides = {})
    issue = create_issue({ status: 'pending' }.merge(overrides))
    issue.start_processing! # -> cloning, a mark_failed source state
    issue
  end

  # --- the guard -------------------------------------------------------

  def test_it_cannot_be_called_without_deciding_the_stamp
    issue = active_issue

    assert_raises(ArgumentError) { runner.send(:safe_mark_failed!, issue) }
  end

  # --- scheduling a retry ------------------------------------------------

  def test_a_caller_scheduling_a_retry_stamps_it
    issue = active_issue
    at = 5.minutes.from_now

    runner.send(:safe_mark_failed!, issue, next_retry_at: at)

    assert_equal 'error', issue.reload.status
    assert_in_delta at.to_i, issue.next_retry_at.to_i, 1
  end

  # --- scheduling none, deliberately --------------------------------------

  def test_a_caller_scheduling_none_clears_a_fresh_column
    issue = active_issue

    runner.send(:safe_mark_failed!, issue, next_retry_at: nil)

    assert_equal 'error', issue.reload.status
    assert_nil issue.next_retry_at
  end

  # The 15888 mirror: a stamp surviving from a previous life in `error` must
  # not survive a fresh entry that deliberately schedules nothing. Left alone,
  # `next_retry_at <= now` reads true forever, and the row is picked up on
  # every single cycle with no backoff at all.
  def test_a_caller_scheduling_none_clears_a_stale_residual_stamp
    issue = active_issue(next_retry_at: Time.zone.parse('2026-05-14 00:00:00'))

    runner.send(:safe_mark_failed!, issue, next_retry_at: nil)

    assert_nil issue.reload.next_retry_at
  end
end

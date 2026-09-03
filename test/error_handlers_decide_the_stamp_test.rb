# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/danger_claude_runner'
require 'autodev/issue_notifier'
require 'autodev/pipeline_monitor'
require 'autodev/mr_fixer'
require 'autodev/issue_processor'

# Autodev #103: every writer of `error` funnels through `safe_mark_failed!`,
# which now takes the stamp decision explicitly. This exercises the decision
# each of the five call sites makes, on all three workers where they exist,
# with a focus on the mirror defect — a stamp surviving from a previous life
# in `error` (15888's `2026-05-14`) must not survive a fresh entry that
# schedules no retry.
class ErrorHandlersDecideTheStampTest < Minitest::Test
  include DatabaseTestHelper

  # Swallows every GitLab call the handlers make in passing (posting the
  # activity-log note, the error comment) — none of it is under test here.
  class SilentClient
    def method_missing(*, **) = nil
    def respond_to_missing?(*) = true
  end

  STALE_STAMP = Time.zone.parse('2026-05-14 00:00:00')

  def setup = setup_database

  def issue_with_stale_stamp(status:, **overrides)
    create_issue({ status: status, next_retry_at: STALE_STAMP }.merge(overrides))
  end

  def worker(klass)
    w = klass.allocate
    w.instance_variable_set(:@project_path, 'group/project')
    w.instance_variable_set(:@project_config, {})
    w.instance_variable_set(:@config, {})
    w.instance_variable_set(:@client, SilentClient.new)
    w.instance_variable_set(:@logger, StubLogger.new)
    w.instance_variable_set(:@dc_stdout, '')
    w.instance_variable_set(:@dc_stderr, '')
    w
  end

  # --- handle_auth_failure: no retry, ever, on all three workers ---------

  def test_pipeline_monitor_auth_failure_clears_a_stale_stamp
    issue = issue_with_stale_stamp(status: 'fixing_pipeline')
    worker(PipelineMonitor).send(:handle_auth_failure, issue, AuthenticationError.new('401'))

    assert_equal 'error', issue.reload.status
    assert_nil issue.next_retry_at
  end

  def test_mr_fixer_auth_failure_clears_a_stale_stamp
    issue = issue_with_stale_stamp(status: 'fixing_discussions')
    worker(MrFixer).send(:handle_auth_failure, issue, AuthenticationError.new('401'))

    assert_equal 'error', issue.reload.status
    assert_nil issue.next_retry_at
  end

  def test_issue_processor_auth_failure_clears_a_stale_stamp
    issue = issue_with_stale_stamp(status: 'implementing')
    worker(IssueProcessor).send(:handle_auth_failure, issue, AuthenticationError.new('401'))

    assert_equal 'error', issue.reload.status
    assert_nil issue.next_retry_at
  end

  # --- the two generic handlers: no retry scheduled either ---------------
  #
  # A policy question left open (see the design doc's Out of scope), but the
  # decision must still be explicit, and the row must not be stranded — the
  # widened DormantAudit#error_arm recovers it.

  def test_pipeline_monitor_generic_failure_clears_a_stale_stamp
    issue = issue_with_stale_stamp(status: 'fixing_pipeline')
    worker(PipelineMonitor).send(:handle_failure_error, issue, RuntimeError.new('boom'))

    assert_equal 'error', issue.reload.status
    assert_nil issue.next_retry_at
  end

  def test_mr_fixer_generic_fix_error_clears_a_stale_stamp
    issue = issue_with_stale_stamp(status: 'fixing_discussions')
    worker(MrFixer).send(:handle_fix_error, issue, RuntimeError.new('boom'))

    assert_equal 'error', issue.reload.status
    assert_nil issue.next_retry_at
  end

  # --- handle_rate_limit: a retry IS scheduled, at the reset time --------

  def test_pipeline_monitor_rate_limit_schedules_a_retry
    issue = issue_with_stale_stamp(status: 'fixing_pipeline')
    worker(PipelineMonitor).send(:handle_rate_limit, issue, RateLimitError.new('quota'))

    assert_equal 'error', issue.reload.status
    assert_operator issue.next_retry_at, :>, Time.current
  end

  def test_mr_fixer_rate_limit_schedules_a_retry
    issue = issue_with_stale_stamp(status: 'fixing_discussions')
    worker(MrFixer).send(:handle_rate_limit, issue, RateLimitError.new('quota'))

    assert_equal 'error', issue.reload.status
    assert_operator issue.next_retry_at, :>, Time.current
  end

  def test_issue_processor_rate_limit_schedules_a_retry
    issue = issue_with_stale_stamp(status: 'implementing')
    worker(IssueProcessor).send(:handle_rate_limit, issue, RateLimitError.new('quota'))

    assert_equal 'error', issue.reload.status
    assert_operator issue.next_retry_at, :>, Time.current
  end

  # --- handle_process_error: backoff while in budget, cleared past it ----

  def test_issue_processor_process_error_schedules_a_retry_within_budget
    issue = issue_with_stale_stamp(status: 'implementing')
    worker(IssueProcessor).send(:handle_process_error, issue, RuntimeError.new('boom'))

    assert_equal 'error', issue.reload.status
    assert_operator issue.next_retry_at, :>, Time.current
  end

  # `Config.max_retries` defaults to 1: the second failure is past budget, and
  # the stamp must be cleared rather than left at whatever the first failure
  # (or, here, a stale residual) wrote.
  def test_issue_processor_process_error_clears_the_stamp_past_budget
    issue = issue_with_stale_stamp(status: 'implementing', retry_count: 1)
    worker(IssueProcessor).send(:handle_process_error, issue, RuntimeError.new('boom'))

    assert_equal 'error', issue.reload.status
    assert_nil issue.next_retry_at
  end
end

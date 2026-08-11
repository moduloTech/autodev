# frozen_string_literal: true

require 'English'
require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/pipeline_monitor/reviewer'

# What autodev says when mr-review fails (Autodev #49).
#
# It used to say almost nothing: the call kept stderr and threw stdout away, and
# mr-review fails writing nothing to stderr. Every retained production log tells
# the same story — 15 failures, 15 lines reading exactly
# "mr-review failed (non-fatal): ", no exceptions, ~1s per attempt once the 15s
# pre-sleep is subtracted. Three tickets hit REVIEW_FAILURE_THRESHOLD on those
# failures and were delivered with no review at all (#16415/!11343,
# #16224/!11187, #12852/!11286), and the cause is still unknown because the only
# copy of it was discarded at the call site.
#
# So the failure message must carry: the exit status, both streams, an explicit
# marker for an empty one, a bounded and announced truncation, and no secrets.
class PipelineMonitorReviewDiagnosticTest < Minitest::Test
  include DatabaseTestHelper

  MR_URL = 'https://gitlab.example/mr/1'

  # Host for the mr-review call path only — the full PipelineMonitor pulls in far
  # more than this needs.
  class Harness
    include DangerClaudeRunner
    include PipelineMonitor::Reviewer

    def initialize(issue:, logger:)
      init_runner(client: nil, config: {}, project_config: { 'path' => 'group/project' },
                  logger: logger, token: 'tok')
      @dc_issue = issue
    end

    # Kernel#sleep stand-in so the test doesn't actually wait 15s.
    def sleep(_seconds); end
  end

  def setup
    setup_database
    @issue = create_issue(status: 'reviewing')
    @logger = StubLogger.new
    @harness = Harness.new(issue: @issue, logger: @logger)
    @harness.define_singleton_method(:command_exists?) { |_cmd| true }
  end

  # Drives one failing mr-review run and returns the message that was logged.
  def failure_message(out: '', err: '', status: exited(1))
    @harness.define_singleton_method(:run_with_timeout) { |*| [out, err, false, status] }
    @harness.send(:run_mr_review_command, MR_URL)
    @logger.messages.last
  end

  # Process::Status cannot be constructed directly; a real (trivial) child gives
  # us a genuine one, which is what the production path hands over.
  def exited(code)
    system("exit #{code}")
    $CHILD_STATUS
  end

  def signalled
    Process.wait(Process.spawn('/bin/sh', '-c', 'kill -9 $$'))
    $CHILD_STATUS
  end

  # The regression. mr-review writes its error to stdout; autodev threw it away.
  def test_stdout_reaches_the_failure_message
    assert_includes failure_message(out: 'unknown option -H'), 'unknown option -H'
  end

  # The half that already worked must not be traded for the half being added.
  def test_stderr_still_reaches_the_failure_message
    assert_includes failure_message(err: 'boom on stderr'), 'boom on stderr'
  end

  def test_an_empty_stream_is_marked_rather_than_left_blank
    message = failure_message(out: 'only stdout spoke')

    assert_includes message, 'only stdout spoke'
    assert_includes message, 'stderr: (empty)'
  end

  # The shape of all 15 production lines: a message ending in a colon, which
  # reads as a logging bug rather than as a finding. Silence must be asserted.
  def test_two_empty_streams_produce_an_explicit_statement
    message = failure_message

    assert_includes message, 'no output on stdout or stderr'
    refute_match(/:\s*\z/, message, 'the message must not trail off after a colon')
  end

  def test_the_exit_status_is_reported
    assert_includes failure_message(status: exited(127)), 'exit 127'
  end

  def test_a_signalled_process_is_reported_as_such
    assert_includes failure_message(status: signalled), 'signal 9'
  end

  # A stub (or a future caller) returning the old three-element tuple must not
  # crash the diagnostic path — it degrades to saying the status is missing.
  def test_a_missing_status_degrades_instead_of_raising
    @harness.define_singleton_method(:run_with_timeout) { |*| ['out', 'err', false] }
    @harness.send(:run_mr_review_command, MR_URL)

    assert_includes @logger.messages.last, 'exit status unavailable'
  end

  def test_a_long_stream_is_truncated_and_says_how_much_was_dropped
    limit = PipelineMonitor::Reviewer::DIAGNOSTIC_STREAM_LIMIT
    message = failure_message(out: 'x' * (limit + 42))

    assert_includes message, '(42 more characters)'
    assert_operator message.length, :<, limit + 500, 'the whole stream must not reach the log'
  end

  def test_a_stream_at_the_limit_is_not_marked_as_truncated
    limit = PipelineMonitor::Reviewer::DIAGNOSTIC_STREAM_LIMIT

    refute_includes failure_message(out: 'x' * limit), 'more characters'
  end

  # The production logger on this path is Autodev::JobLogger, which — unlike
  # AppLogger — does not scrub. We are printing an external tool's raw output,
  # and mr-review holds the same GitLab PAT autodev does.
  def test_a_gitlab_token_in_the_output_is_scrubbed
    message = failure_message(out: 'auth failed for glpat-AbCdEf123456')

    refute_includes message, 'glpat-AbCdEf123456'
    assert_includes message, '***'
  end

  def test_the_success_path_logs_no_error_and_returns_true
    success = exited(0)
    @harness.define_singleton_method(:run_with_timeout) { |*| ['review body', '', true, success] }

    assert @harness.send(:run_mr_review_command, MR_URL)
    refute(@logger.messages.any? { |m| m.include?('failed') })
  end
end

# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'
require 'autodev/danger_claude_runner'
require 'autodev/pipeline_monitor/reviewer'

# The `reviewing` state's silence contract (Autodev #50, then #54).
#
# mr-review is an LLM review of a full MR diff. It used to run via a raw
# Open3.capture3 with no timeout, which made `reviewing` — a state
# dispatch_dormant_audit repositions rows out of — able to stay silent forever
# under a live worker. #50 added a heartbeat immediately before the call, bounding
# that silence at one mr-review run; #54 routes the call through
# ProcessRunner#run_with_timeout, so "one run" is now a bounded number of seconds
# (the new per-project mr_review_timeout, baked default 3600s), a term
# HealthReport#longest_worker_timeout now accounts for.
#
# The timeout must stay NON-FATAL: run_with_timeout raises, execute_mr_review's
# rescue turns that into `false`, and launch_review counts it as a review failure
# (review_failure_count, threshold 5) rather than dropping the request to `error`.
class PipelineMonitorReviewHeartbeatTest < Minitest::Test
  include DatabaseTestHelper

  # Host for PipelineMonitor::Reviewer's mr-review call path. Only
  # DangerClaudeRunner + Reviewer are mixed in — the full PipelineMonitor class
  # pulls in far more than this call path needs.
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
    @harness = Harness.new(issue: @issue, logger: StubLogger.new)
    @harness.define_singleton_method(:command_exists?) { |_cmd| true }
  end

  def heartbeats
    ActivityEvent.where(issue_id: @issue.id, kind: 'heartbeat').order(:id).to_a
  end

  # Records what reached the timeout wrapper and returns the triple it produces.
  def stub_timeout_wrapper(result)
    calls = []
    @harness.define_singleton_method(:run_with_timeout) do |cmd, args, **opts|
      calls << { cmd: cmd, args: args, opts: opts }
      result
    end
    calls
  end

  # The point of the ticket: the call is wrapped, not raw. Without this
  # assertion a revert to Open3.capture3 would leave every other test green.
  def test_mr_review_runs_through_the_timeout_wrapper
    calls = stub_timeout_wrapper(['', '', true])
    Open3.stub :capture3, ->(*) { raise 'Open3.capture3 must not be on the mr-review path' } do
      @harness.send(:run_mr_review_command, 'https://gitlab.example/mr/1')
    end

    assert_equal 1, calls.size
    assert_equal 'mr-review', calls.first[:cmd]
    assert_equal ['-H', 'https://gitlab.example/mr/1'], calls.first[:args]
  end

  # chdir is required by run_with_timeout and was implicit with Open3.capture3.
  # It was Dir.pwd — the worker's inherited cwd — until Autodev #77 made it a
  # declared neutral directory; mr-review clones the MR itself and uses absolute
  # paths for everything else, so the value only has to exist. The reasoning, and
  # the pin that the worker's cwd is no longer an input, live in
  # test/mr_review_runs_in_a_neutral_directory_test.rb.
  def test_the_wrapper_is_called_with_a_neutral_directory
    calls = stub_timeout_wrapper(['', '', true])
    @harness.send(:run_mr_review_command, 'https://gitlab.example/mr/1')

    assert_equal Dir.tmpdir, calls.first[:opts][:chdir]
  end

  def test_the_success_path_returns_true
    stub_timeout_wrapper(['', '', true])

    assert @harness.send(:run_mr_review_command, 'https://gitlab.example/mr/1')
  end

  def test_the_failure_path_returns_false
    stub_timeout_wrapper(['', 'boom', false])

    refute @harness.send(:run_mr_review_command, 'https://gitlab.example/mr/1')
  end

  # The non-fatal contract. run_with_timeout raises ImplementationError on
  # timeout; execute_mr_review's rescue must absorb it and answer `false`, which
  # is what launch_review reads to increment review_failure_count instead of
  # failing the request.
  def test_a_timeout_is_absorbed_and_answers_false
    @harness.define_singleton_method(:run_with_timeout) do |*|
      raise ImplementationError, 'mr-review timed out after 1800s'
    end

    result = @harness.send(:execute_mr_review, @issue)

    refute result, 'a timeout must be absorbed into false, not raised'
  end

  # The heartbeat is written before the call, so a killed run still leaves proof
  # the worker was alive up to that moment — which is what keeps the dormant
  # audit off the row.
  def test_a_timeout_still_leaves_exactly_one_heartbeat
    @harness.define_singleton_method(:run_with_timeout) do |*|
      raise ImplementationError, 'mr-review timed out after 1800s'
    end
    @harness.send(:execute_mr_review, @issue)

    assert_equal 1, heartbeats.size
    assert_equal 'mr-review', heartbeats.first.payload['label']
  end

  def test_execute_mr_review_writes_one_heartbeat
    stub_timeout_wrapper(['', '', true])
    @harness.send(:execute_mr_review, @issue)

    assert_equal 1, heartbeats.size
    assert_equal 'mr-review', heartbeats.first.payload['label']
  end

  def test_heartbeat_is_written_even_when_mr_review_fails
    stub_timeout_wrapper(['', 'boom', false])
    @harness.send(:execute_mr_review, @issue)

    assert_equal 1, heartbeats.size
  end

  # The cap is mr_review_timeout, not dc_timeout: a review's duration profile is
  # not an implementation call's (production data: 317 reviews, longest 2641s and
  # successful, against dc_timeout's 1800s default).
  def test_the_wrapper_is_called_with_the_baked_review_timeout
    calls = stub_timeout_wrapper(['', '', true])
    @harness.send(:run_mr_review_command, 'https://gitlab.example/mr/1')

    assert_equal Config::MR_REVIEW_TIMEOUT, calls.first[:opts][:timeout]
  end

  def test_a_project_override_wins_over_the_baked_review_timeout
    harness = Harness.new(issue: @issue, logger: StubLogger.new)
    harness.instance_variable_set(:@project_config, { 'path' => 'group/project', 'mr_review_timeout' => 5400 })
    harness.define_singleton_method(:command_exists?) { |_cmd| true }
    calls = []
    harness.define_singleton_method(:run_with_timeout) do |cmd, args, **opts|
      calls << { cmd: cmd, args: args, opts: opts }
      ['', '', true]
    end
    harness.send(:run_mr_review_command, 'https://gitlab.example/mr/1')

    assert_equal 5400, calls.first[:opts][:timeout]
  end

  # ProcessRunner builds its tag as "#{cmd} #{label}", so label: 'mr-review'
  # would read "mr-review mr-review timed out after 3600s".
  def test_no_redundant_label_is_passed
    calls = stub_timeout_wrapper(['', '', true])
    @harness.send(:run_mr_review_command, 'https://gitlab.example/mr/1')

    refute calls.first[:opts].key?(:label), 'cmd already names the command'
  end
end

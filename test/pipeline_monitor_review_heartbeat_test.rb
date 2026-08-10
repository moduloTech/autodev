# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'
require 'autodev/danger_claude_runner'
require 'autodev/pipeline_monitor/reviewer'

# mr-review is an LLM review invoked via Open3.capture3 with no timeout, and it
# is not a danger-claude call, so it gets no heartbeat of its own and appears in
# no term of HealthReport#longest_worker_timeout (Autodev #50 final-review
# finding: `reviewing` is a second exception the original enumeration missed,
# since it only walked danger-claude call sites, not every Open3 shell-out).
#
# run_mr_review_command now calls dc_heartbeat!('mr-review') immediately before
# the Open3 call, so silence in `reviewing` is bounded to one mr-review run
# instead of being unbounded. This pins that a heartbeat is actually written.
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
  end

  def heartbeats
    ActivityEvent.where(issue_id: @issue.id, kind: 'heartbeat').order(:id).to_a
  end

  def test_execute_mr_review_writes_one_heartbeat
    @harness.define_singleton_method(:command_exists?) { |_cmd| true }
    fake_status = Struct.new(:success?).new(true)
    Open3.stub :capture3, ['', '', fake_status] do
      @harness.send(:execute_mr_review, @issue)
    end

    assert_equal 1, heartbeats.size
    assert_equal 'mr-review', heartbeats.first.payload['label']
  end

  def test_heartbeat_is_written_even_when_mr_review_fails
    @harness.define_singleton_method(:command_exists?) { |_cmd| true }
    fake_status = Struct.new(:success?).new(false)
    Open3.stub :capture3, ['', 'boom', fake_status] do
      @harness.send(:execute_mr_review, @issue)
    end

    assert_equal 1, heartbeats.size
  end
end

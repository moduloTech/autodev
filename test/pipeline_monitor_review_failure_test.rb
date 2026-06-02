# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/pipeline_monitor'

# Regression: a persistently broken mr-review (token expired, binary crash,
# transient GitLab errors) used to leave Autodev in an infinite
# checking_pipeline ↔ reviewing loop because `review_done!` fired regardless
# of mr-review's exit status, and only `review_count` was capped — failures
# never incremented it. Observed on Powerpanne issue #11859 (2026-05-28):
# 36 short-lived reviewing transitions in ~90 minutes before a single
# successful run finally broke the loop.
#
# Now: consecutive mr-review failures increment `review_failure_count`;
# at REVIEW_FAILURE_THRESHOLD we fire `review_giveup!` (reviewing → done)
# with an alert. A successful run resets the counter.
class PipelineMonitorReviewFailureTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_CONFIG = { 'path' => 'group/project' }.freeze

  def setup
    setup_database
    @issue = build_reviewing_issue
    @monitor = build_monitor
  end

  def test_failed_review_increments_failure_counter
    stub_mr_review(success: false)

    @monitor.send(:launch_review, @issue)
    @issue.refresh

    assert_equal 1, @issue.review_failure_count
  end

  def test_failed_review_under_threshold_returns_to_checking_pipeline
    stub_mr_review(success: false)

    @monitor.send(:launch_review, @issue)
    @issue.refresh

    assert_equal 'checking_pipeline', @issue.status
  end

  def test_threshold_reached_transitions_to_done
    @issue.update(review_failure_count: PipelineMonitor::Reviewer::REVIEW_FAILURE_THRESHOLD - 1)
    stub_mr_review(success: false)

    @monitor.send(:launch_review, @issue)
    @issue.refresh

    assert_equal 'done', @issue.status
  end

  def test_successful_review_resets_failure_counter
    @issue.update(review_failure_count: 3)
    stub_mr_review(success: true)

    @monitor.send(:launch_review, @issue)
    @issue.refresh

    assert_equal 0, @issue.review_failure_count
  end

  def test_successful_review_increments_review_count
    @issue.update(review_count: 0, review_failure_count: 2)
    stub_mr_review(success: true)

    @monitor.send(:launch_review, @issue)
    @issue.refresh

    assert_equal 1, @issue.review_count
  end

  private

  def build_reviewing_issue
    issue = create_issue(mr_iid: 1, mr_url: 'https://gitlab.example/group/project/-/merge_requests/1',
                         issue_author_id: 7, review_count: 0)
    advance_to(issue, 'checking_pipeline')
    issue._review_count_zero = true
    issue.pipeline_green!

    assert_equal 'reviewing', issue.status
    issue
  end

  def build_monitor
    monitor = PipelineMonitor.allocate
    monitor.instance_variable_set(:@project_path, 'group/project')
    monitor.instance_variable_set(:@project_config, PROJECT_CONFIG)
    monitor.instance_variable_set(:@logger, StubLogger.new)
    monitor.instance_variable_set(:@client, NoopClient.new)
    monitor.instance_variable_set(:@dc_issue, @issue)
    monitor
  end

  def stub_mr_review(success:)
    @monitor.define_singleton_method(:execute_mr_review) { |_| success }
  end

  # Swallows every GitLab API call that the finalize / giveup paths fan out
  # to (label updates, reassignment, activity-note upserts, notifications).
  # We assert on persisted state, not on API traffic, so a noop is enough.
  class NoopClient
    def method_missing(_name, *_args, **_kwargs)
      Struct.new(:id, :labels, :assignee, :assignees, :body).new(1, [], nil, [], 'body')
    end

    def respond_to_missing?(_name, _include_private = false)
      true
    end
  end
end

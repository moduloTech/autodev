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
# That fix made every non-success answer `false`, counted identically whether
# mr-review was merely absent, crashed, timed out, or exited non-zero — and
# `false` was never a verdict on the merge request in the first place: the
# binary posts its own findings straight to GitLab, so its exit status carries
# nothing autodev can read as "this MR failed review" versus "the tool could
# not run at all". Autodev #107 corrects that: every non-success outcome on
# this path is `:tool_unavailable`, and `dispatch_review_outcome` no longer
# spends `review_failure_count` on it — the binary path spent its credential
# revoked for four months (Autodev #80) while this counter was the only thing
# watching and never said so. The row still comes back to `checking_pipeline`
# exactly as before (so the old infinite-loop regression above stays fixed);
# what changed is that it costs nothing to get there, and the row is bounded
# by `pipeline_watch_max_days` instead of `REVIEW_FAILURE_THRESHOLD`.
#
# A successful run still resets the counter and increments `review_count`,
# unchanged.
class PipelineMonitorReviewFailureTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_CONFIG = { 'path' => 'group/project' }.freeze

  def setup
    setup_database
    @issue = build_reviewing_issue
    @monitor = build_monitor
  end

  def test_failed_review_does_not_increment_the_failure_counter
    stub_mr_review(outcome: :tool_unavailable)

    @monitor.send(:launch_review, @issue)
    @issue.reload

    assert_equal 0, @issue.review_failure_count
  end

  def test_failed_review_returns_to_checking_pipeline
    stub_mr_review(outcome: :tool_unavailable)

    @monitor.send(:launch_review, @issue)
    @issue.reload

    assert_equal 'checking_pipeline', @issue.status
  end

  # The regression this file exists to pin, restated for #107: five
  # consecutive mr-review failures — what used to reach
  # `REVIEW_FAILURE_THRESHOLD` and abandon the request — no longer spend
  # anything or conclude anything on the binary path.
  def test_five_consecutive_failures_neither_spend_the_budget_nor_abandon_the_request
    5.times do
      stub_mr_review(outcome: :tool_unavailable)
      @monitor.send(:launch_review, @issue)
    end
    @issue.reload

    assert_equal 0, @issue.review_failure_count
    assert_equal 'checking_pipeline', @issue.status
    refute @issue.needs_attention
  end

  def test_successful_review_resets_failure_counter
    @issue.update(review_failure_count: 3)
    stub_mr_review(outcome: true)

    @monitor.send(:launch_review, @issue)
    @issue.reload

    assert_equal 0, @issue.review_failure_count
  end

  def test_successful_review_increments_review_count
    @issue.update(review_count: 0, review_failure_count: 2)
    stub_mr_review(outcome: true)

    @monitor.send(:launch_review, @issue)
    @issue.reload

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

  def stub_mr_review(outcome:)
    @monitor.define_singleton_method(:execute_mr_review) { |_| outcome }
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

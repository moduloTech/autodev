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
# not run at all". Autodev #107 corrects that: no non-success outcome on this
# path spends `review_failure_count` any more — the binary path spent its
# credential revoked for four months (Autodev #80) while this counter was the
# only thing watching and never said so.
#
# The alpha-53 reviews then split one outcome in two. An **absent binary** is
# a configuration fact, true on every poll until somebody installs it, so it
# gives up at once (`:tool_missing`) instead of waiting fourteen days to end
# under a reason about the watch. A tool that **could not run** keeps
# working and is bounded by the age bound, `pipeline_watch_max_days`, whose
# give-up sentence is true of it.
#
# A per-cause counter was tried in between and removed: keyed on the failure's
# message it is inert (git's `after 75002 ms` moves every attempt — Autodev
# #99's defect), and keyed on a stable message it gives a healthy request up
# after a ten-minute burst of GitLab 502s. Neither spends the review budget,
# which is #107's rule and is what these tests pin.
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

  # The regression this file exists to pin: five consecutive mr-review
  # failures spend **nothing** of the review budget and conclude nothing on
  # their own count. What ends such a row is the age bound, exercised in
  # `an_outage_is_not_a_review_verdict_test.rb`.
  def test_five_consecutive_failures_spend_no_budget_and_conclude_nothing
    5.times do
      stub_mr_review(outcome: :tool_unavailable)
      @monitor.send(:launch_review, @issue)
    end
    @issue.reload

    assert_equal [0, 'checking_pipeline'], [@issue.review_failure_count, @issue.status]
    refute @issue.needs_attention
  end

  # `mr-review` absent is deterministic and known on the first poll, so it is
  # a give-up rather than a wait — and the outcome is produced by the real
  # `command_exists?`, not stubbed past, because the whole point is that this
  # branch is reached from a PATH lookup (second review, N8).
  def test_an_absent_binary_gives_up_at_once_under_its_own_reason
    @monitor.define_singleton_method(:command_exists?) { |_| false }

    @monitor.send(:launch_review, @issue)
    @issue.reload

    assert_equal 'done', @issue.status
    assert_equal 'review_tool_missing', @issue.attention_reason
    assert_equal 0, @issue.review_failure_count
  end

  # The other side of the same lookup: a binary that IS on PATH must not take
  # the give-up branch.
  def test_a_present_binary_does_not_give_up
    @monitor.define_singleton_method(:command_exists?) { |_| true }
    @monitor.define_singleton_method(:run_mr_review_command) { |_| true }
    @monitor.define_singleton_method(:sleep) { |_| nil }

    @monitor.send(:launch_review, @issue)
    @issue.reload

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
    monitor.instance_variable_set(:@config, {})
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

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
# The alpha-53 neutral review (G3) then put a bound back, because #107 had
# left `pipeline_watch_max_days` — fourteen days — as the only thing ending a
# row whose review tool cannot run, under a reason that says the watch stopped
# moving. Two outcomes now, not one: an **absent binary** is a configuration
# fact and gives up at once (`:tool_missing`), and a tool that **could not
# run** is counted by `ReviewOutageBound` and gives up after
# `stagnation_threshold` occurrences of the same cause. Neither spends the
# review budget, which is #107's rule, and both end under a reason that is
# true.
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

  # The regression this file exists to pin, restated twice. Five consecutive
  # mr-review failures still spend **nothing** of the review budget (#107's
  # rule), and they do now conclude — under `review_tool_unavailable`, which
  # says what happened, rather than after fourteen days under
  # `pipeline_watch_expired`, which would not (alpha-53 review, G3).
  def test_five_consecutive_failures_spend_no_budget_and_end_under_the_outage_reason # rubocop:disable Minitest/MultipleAssertions
    5.times do
      stub_mr_review(outcome: :tool_unavailable)
      @monitor.send(:launch_review, @issue)
    end
    @issue.reload

    assert_equal 0, @issue.review_failure_count, "#107's rule: an outage never spends the review budget"
    assert_equal 'done', @issue.status
    assert @issue.needs_attention
    assert_equal 'review_tool_unavailable', @issue.attention_reason
  end

  # Below the threshold the row keeps working, which is what makes the bound a
  # bound and not a hair trigger.
  def test_four_consecutive_failures_leave_the_row_watching
    4.times do
      stub_mr_review(outcome: :tool_unavailable)
      @monitor.send(:launch_review, @issue)
    end
    @issue.reload

    assert_equal 'checking_pipeline', @issue.status
    refute @issue.needs_attention
    assert_equal 0, @issue.review_failure_count
  end

  # A cause that changes is a different fact and restarts the count — the rule
  # `ConsecutiveOccurrences` applies everywhere else it is used.
  def test_a_different_cause_restarts_the_count
    4.times { poll_with_outage('docker 500') }
    poll_with_outage('a different failure entirely')

    assert_equal 'checking_pipeline', @issue.reload.status, 'a new cause must not inherit the old count'
  end

  # `mr-review` absent is deterministic and known on the first poll, so it is
  # a give-up rather than a countdown (alpha-53 review, G3a).
  def test_an_absent_binary_gives_up_at_once_under_its_own_reason
    stub_mr_review(outcome: :tool_missing)

    @monitor.send(:launch_review, @issue)
    @issue.reload

    assert_equal 'done', @issue.status
    assert_equal 'review_tool_missing', @issue.attention_reason
    assert_equal 0, @issue.review_failure_count
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

  # One poll whose review tool failed with `diagnostic` — the value
  # `ReviewOutageBound` counts as "the same cause".
  def poll_with_outage(diagnostic)
    @monitor.define_singleton_method(:execute_mr_review) do |_|
      @review_outage_diagnostic = diagnostic
      :tool_unavailable
    end
    @monitor.send(:launch_review, @issue)
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

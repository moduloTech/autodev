# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/danger_claude_runner'
require 'autodev/issue_notifier'
require 'autodev/label_manager'
require 'autodev/activity_logger'
require 'autodev/issue_processor'
require 'autodev/poll_router'
require 'autodev/pipeline_monitor'

# Covers the automatic infra-recovery recheck end to end at the DB boundary:
#   1. PollDispatcher#fetch_infra_recheck_candidates selects only open,
#      under-cap, backoff-elapsed `stagnation_pipeline` tickets (never a
#      discussion stagnation, review-limit give-up, or capped/backed-off row).
#   2. PollRouter#resume_recovered_infra re-enters `checking_pipeline` with
#      needs_attention cleared — reusing ResumeHandler#reenter_via_pipeline_check.
class InfraRecheckDispatchTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_CONFIG = {
    'path' => 'group/project',
    'labels_todo' => ['To do'],
    'label_doing' => 'Doing',
    'label_done' => 'Done'
  }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example' }.freeze

  FakeMr = Struct.new(:state)
  FakeGlIssue = Struct.new(:iid, :title)

  # Label + activity no-op client (mirrors poll_router_reenter_test).
  class StubClient
    def merge_request(_project, _iid) = FakeMr.new('opened')
    def issue(_project, _iid) = Struct.new(:labels).new([])
    def edit_issue(_project, _iid, **_opts) = nil
    def create_issue_note(_project, _iid, _body) = Struct.new(:id).new(123)
  end

  def setup
    setup_database
    @logger = StubLogger.new
  end

  # -- candidate query --

  def dispatcher(project_config: PROJECT_CONFIG, config: CONFIG)
    Autodev::PollDispatcher.allocate.tap do |d|
      d.instance_variable_set(:@path, project_config['path'])
      d.instance_variable_set(:@project_config, project_config)
      d.instance_variable_set(:@config, config)
    end
  end

  def candidate_iids(**)
    dispatcher(**).send(:fetch_infra_recheck_candidates).map(&:issue_iid)
  end

  def infra_stagnation_issue(overrides = {})
    create_issue({ status: 'done', mr_iid: 42, needs_attention: true,
                   attention_reason: 'stagnation_pipeline' }.merge(overrides))
  end

  def test_selects_open_under_cap_backoff_elapsed_infra_stagnation
    issue = infra_stagnation_issue

    assert_includes candidate_iids, issue.issue_iid
  end

  def test_selects_when_backoff_is_in_the_past
    issue = infra_stagnation_issue(infra_recheck_count: 2, infra_recheck_at: 1.hour.ago)

    assert_includes candidate_iids, issue.issue_iid
  end

  def test_excludes_when_backoff_is_in_the_future
    issue = infra_stagnation_issue(infra_recheck_at: 1.hour.from_now)

    refute_includes candidate_iids, issue.issue_iid
  end

  def test_excludes_when_cap_reached
    issue = infra_stagnation_issue(infra_recheck_count: PipelineMonitor::DEFAULT_INFRA_RECHECK_MAX)

    refute_includes candidate_iids, issue.issue_iid
  end

  def test_cap_is_configurable
    issue = infra_stagnation_issue(infra_recheck_count: 2)

    refute_includes candidate_iids(config: CONFIG.merge('infra_recheck_max' => 2)), issue.issue_iid
  end

  def test_excludes_discussion_stagnation
    issue = infra_stagnation_issue(attention_reason: 'stagnation_discussions')

    refute_includes candidate_iids, issue.issue_iid
  end

  def test_excludes_other_needs_attention_reasons
    issue = infra_stagnation_issue(attention_reason: 'review_limit_reached')

    refute_includes candidate_iids, issue.issue_iid
  end

  # The load-bearing half of Autodev #60's item 2. Every give-up path now
  # shares one AASM event and one reassignment policy, but NOT one
  # `attention_reason` — this pass selects `stagnation_pipeline` and re-arms the
  # row, so a give-up that is not a deferral must never carry that value. Collapse
  # the reasons and autodev restarts tickets it has just abandoned.
  def test_only_a_pipeline_stagnation_is_ever_re_armed
    reasons = %w[stagnation_pipeline stagnation_discussions pipeline_watch_expired
                 review_limit_reached review_failures_exhausted dormant_exhausted
                 mr_closed_unmerged]
    issues = reasons.to_h { |reason| [reason, infra_stagnation_issue(attention_reason: reason)] }
    selected = candidate_iids

    assert_equal([issues['stagnation_pipeline'].issue_iid],
                 issues.values.map(&:issue_iid).select { |iid| selected.include?(iid) })
  end

  def test_excludes_when_not_flagged_needs_attention
    issue = infra_stagnation_issue(needs_attention: false)

    refute_includes candidate_iids, issue.issue_iid
  end

  def test_excludes_when_no_mr
    issue = infra_stagnation_issue(mr_iid: nil)

    refute_includes candidate_iids, issue.issue_iid
  end

  # -- recovery re-entry --

  def test_resume_recovered_infra_reenters_checking_pipeline_and_clears_attention
    issue = infra_stagnation_issue(review_count: 3, infra_recheck_count: 2)

    build_router.resume_recovered_infra(issue, StubClient.new)
    issue.reload

    assert_equal 'checking_pipeline', issue.status
    assert_nil issue.attention_reason
    refute issue.needs_attention
  end

  def test_resume_recovered_infra_resets_review_count_to_one
    issue = infra_stagnation_issue(review_count: 3)

    build_router.resume_recovered_infra(issue, StubClient.new)

    assert_equal 1, issue.reload.review_count
  end

  private

  def build_router
    PollRouter.new(config: CONFIG, project_config: PROJECT_CONFIG,
                   logger: @logger, token: 'x', pool: nil)
  end
end

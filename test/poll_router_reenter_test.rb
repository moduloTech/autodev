# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/danger_claude_runner'
require 'autodev/issue_notifier'
require 'autodev/label_manager'
require 'autodev/activity_logger'
require 'autodev/worker_pool'
require 'autodev/issue_processor'
require 'autodev/poll_router'

# Regression: when an issue reaches `done` with an open MR carrying unresolved
# discussions, re-adding the `To do` label should route to `checking_pipeline`
# (which then dispatches to `fixing_discussions`) instead of triggering a full
# re-implementation cycle. Observed on Powerpanne issue #11859 (2026-05-28):
# autodev re-implemented from scratch and never addressed the existing 12
# unresolved threads.
class PollRouterReenterTest < Minitest::Test
  include DatabaseTestHelper

  FakeMr = Struct.new(:state)
  FakeGlIssue = Struct.new(:iid, :title)

  # Pool stub: just record enqueue calls without running them.
  class StubPool
    attr_reader :enqueued

    def initialize
      @enqueued = []
    end

    def enqueue?(issue_iid:, &block)
      @enqueued << { issue_iid: issue_iid, block: block }
      true
    end
  end

  class StubClient
    attr_reader :merge_request_calls, :label_calls

    def initialize(mr_state:)
      @mr_state = mr_state
      @merge_request_calls = []
      @label_calls = []
    end

    def merge_request(project_path, mr_iid)
      @merge_request_calls << [project_path, mr_iid]
      FakeMr.new(@mr_state)
    end

    # Label workflow noops — we don't assert label state in this test, just
    # avoid raising. apply_label_doing reads the issue then edits it.
    def issue(_project_path, _iid)
      Struct.new(:labels).new([])
    end

    def edit_issue(project_path, iid, **opts)
      @label_calls << [project_path, iid, opts]
    end

    # Activity-log no-ops: PollRouter posts a reenter activity via ActivityLogger.
    def create_issue_note(_project_path, _iid, _body)
      Struct.new(:id).new(123)
    end
  end

  PROJECT_CONFIG = {
    'path' => 'group/project',
    'labels_todo' => ['To do'],
    'label_doing' => 'Doing',
    'label_done' => 'Done'
  }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example' }.freeze

  def setup
    setup_database
    @logger = StubLogger.new
    stub_gitlab_client_builder
  end

  def teardown
    GitlabHelpers.singleton_class.alias_method :build_gitlab_client, :original_build_gitlab_client
  end

  # The Gitlab gem isn't loaded in tests; the reimplementation path builds a
  # worker client for the worker pool. Stub it so we don't pull the gem.
  def stub_gitlab_client_builder
    unless GitlabHelpers.respond_to?(:original_build_gitlab_client)
      GitlabHelpers.singleton_class.alias_method :original_build_gitlab_client, :build_gitlab_client
    end
    GitlabHelpers.define_singleton_method(:build_gitlab_client) { |*_| :worker_client_stub }
  end

  def test_reenter_routes_to_checking_pipeline_when_mr_open
    issue = done_issue_with_mr(mr_iid: 42)
    client = StubClient.new(mr_state: 'opened')

    build_router.route(FakeGlIssue.new(issue.issue_iid, 'fake title'), client)
    issue.refresh

    assert_equal 'checking_pipeline', issue.status
  end

  def test_reenter_open_mr_resets_review_count_to_one
    issue = done_issue_with_mr(mr_iid: 42, review_count: 4)
    client = StubClient.new(mr_state: 'opened')

    build_router.route(FakeGlIssue.new(issue.issue_iid, 'fake title'), client)
    issue.refresh

    assert_equal 1, issue.review_count
  end

  def test_reenter_routes_to_pending_when_mr_closed
    issue = done_issue_with_mr(mr_iid: 43)
    client = StubClient.new(mr_state: 'closed')

    verdict = build_router.route(FakeGlIssue.new(issue.issue_iid, 'fake title'), client)

    assert_equal :next, verdict
    issue.refresh

    assert_equal 'pending', issue.status
  end

  def test_reenter_routes_to_pending_when_no_mr
    issue = done_issue_with_mr(mr_iid: nil)
    client = StubClient.new(mr_state: 'opened') # state irrelevant: short-circuit on nil mr_iid

    verdict = build_router.route(FakeGlIssue.new(issue.issue_iid, 'fake title'), client)

    assert_equal :next, verdict
    issue.refresh

    assert_equal 'pending', issue.status
    assert_empty client.merge_request_calls
  end

  def test_reenter_skipped_when_mr_merged
    issue = done_issue_with_mr(mr_iid: 44)
    client = StubClient.new(mr_state: 'merged')

    verdict = build_router.route(FakeGlIssue.new(issue.issue_iid, 'fake title'), client)

    assert_equal :next, verdict
    issue.refresh

    # Stays in done — no AASM transition, no reimplementation cycle.
    assert_equal 'done', issue.status
    # But we still poked GitLab labels to strip todo and re-apply done.
    refute_empty client.label_calls
  end

  private

  def build_router
    PollRouter.new(config: CONFIG, project_config: PROJECT_CONFIG,
                   logger: @logger, token: 'x', pool: StubPool.new)
  end

  def done_issue_with_mr(mr_iid:, review_count: 2)
    issue = create_issue(mr_iid: mr_iid, review_count: review_count)
    advance_to(issue, 'checking_pipeline')
    issue._review_count_over_zero = true
    issue._unresolved_discussions_empty = true
    issue.pipeline_green!

    assert_equal 'done', issue.status
    issue
  end
end

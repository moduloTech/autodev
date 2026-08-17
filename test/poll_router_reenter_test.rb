# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/danger_claude_runner'
require 'autodev/issue_notifier'
require 'autodev/label_manager'
require 'autodev/activity_logger'
require 'autodev/issue_processor'
require 'autodev/poll_router'

# Regression: when an issue reaches `done` with an open MR carrying unresolved
# discussions, re-adding the `To do` label should route to `checking_pipeline`
# (which then dispatches to `fixing_discussions`) instead of triggering a full
# re-implementation cycle. Observed on Powerpanne issue #11859 (2026-05-28):
# autodev re-implemented from scratch and never addressed the existing 12
# unresolved threads.
class PollRouterReenterTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  include DatabaseTestHelper

  FakeMr = Struct.new(:state)
  FakeGlIssue = Struct.new(:iid, :title)
  FakeNote = Struct.new(:system, :created_at, :body)
  FakeLabel = Struct.new(:name)
  FakeLabelEvent = Struct.new(:action, :label, :created_at)

  # Mimics the gitlab gem's paginated response (responds to auto_paginate).
  Paginated = Struct.new(:items) do
    def auto_paginate = items
  end

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

  # `Gitlab::Error::ResponseError` builds its message from the real HTTP
  # response; this is the minimum surface it reads.
  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  def api_error
    Gitlab::Error::ResponseError.new(
      FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/x'))
    )
  end

  class StubClient
    attr_reader :merge_request_calls, :label_calls, :label_event_calls

    def initialize(mr_state:, issue_notes: [], label_events: [], mr_error: nil, notes_error: nil)
      @mr_state = mr_state
      @issue_notes = issue_notes
      @label_events = label_events
      @mr_error = mr_error
      @notes_error = notes_error
      @merge_request_calls = []
      @label_calls = []
      @label_event_calls = 0
    end

    def issue_label_events(_project_path, _iid)
      @label_event_calls += 1
      @label_events
    end

    def merge_request(project_path, mr_iid)
      @merge_request_calls << [project_path, mr_iid]
      raise @mr_error if @mr_error

      FakeMr.new(@mr_state)
    end

    def issue_notes(_project_path, _iid, **_opts)
      raise @notes_error if @notes_error

      Paginated.new(@issue_notes)
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
    issue.reload

    assert_equal 'checking_pipeline', issue.status
  end

  def test_reenter_open_mr_resets_review_count_to_one
    issue = done_issue_with_mr(mr_iid: 42, review_count: 4)
    client = StubClient.new(mr_state: 'opened')

    build_router.route(FakeGlIssue.new(issue.issue_iid, 'fake title'), client)
    issue.reload

    assert_equal 1, issue.review_count
  end

  def test_reenter_routes_to_pending_when_mr_closed
    issue = done_issue_with_mr(mr_iid: 43)
    client = StubClient.new(mr_state: 'closed')

    verdict = build_router.route(FakeGlIssue.new(issue.issue_iid, 'fake title'), client)

    assert_equal :next, verdict
    issue.reload

    assert_equal 'pending', issue.status
  end

  def test_reenter_routes_to_pending_when_no_mr
    issue = done_issue_with_mr(mr_iid: nil)
    client = StubClient.new(mr_state: 'opened') # state irrelevant: short-circuit on nil mr_iid

    verdict = build_router.route(FakeGlIssue.new(issue.issue_iid, 'fake title'), client)

    assert_equal :next, verdict
    issue.reload

    assert_equal 'pending', issue.status
    assert_empty client.merge_request_calls
  end

  # Bug #32 (recette KO): a human re-adds the todo label AND posts a new comment
  # on the ISSUE explaining what's wrong. The MR is still open. Feedback lives on
  # the issue, not on the MR — so route to a full reimplementation (the only path
  # that reads issue comments via fetch_full_context) instead of looping through
  # fixing_discussions and re-delivering the identical MR.
  def test_reenter_reimplements_when_new_issue_comment_posted_after_delivery
    issue = done_issue_with_mr(mr_iid: 42)
    issue.update(finished_at: Time.parse('2026-07-01T10:00:00Z'))
    client = StubClient.new(mr_state: 'opened',
                            issue_notes: [FakeNote.new(system: false, body: 'La recette est KO, il manque X',
                                                       created_at: '2026-07-02T09:00:00Z')])

    verdict = build_router.route(FakeGlIssue.new(issue.issue_iid, 'fake title'), client)
    issue.reload

    assert_equal :next, verdict
    assert_equal 'pending', issue.status
  end

  # A comment predating the last delivery is stale (already accounted for) — keep
  # the existing open-MR behavior (checking_pipeline → fixing_discussions).
  def test_reenter_stays_on_pipeline_when_issue_comment_predates_delivery
    issue = done_issue_with_mr(mr_iid: 42)
    issue.update(finished_at: Time.parse('2026-07-02T10:00:00Z'))
    client = StubClient.new(mr_state: 'opened',
                            issue_notes: [FakeNote.new(system: false, body: 'vieux commentaire',
                                                       created_at: '2026-07-01T09:00:00Z')])

    build_router.route(FakeGlIssue.new(issue.issue_iid, 'fake title'), client)
    issue.reload

    assert_equal 'checking_pipeline', issue.status
  end

  # autodev's own post-delivery comment must not be mistaken for human feedback.
  def test_reenter_ignores_autodev_own_comment_after_delivery
    issue = done_issue_with_mr(mr_iid: 42)
    issue.update(finished_at: Time.parse('2026-07-01T10:00:00Z'))
    client = StubClient.new(mr_state: 'opened',
                            issue_notes: [FakeNote.new(system: false, created_at: '2026-07-02T09:00:00Z',
                                                       body: '**autodev** : MR livrée')])

    build_router.route(FakeGlIssue.new(issue.issue_iid, 'fake title'), client)
    issue.reload

    assert_equal 'checking_pipeline', issue.status
  end

  def test_reenter_skipped_when_mr_merged
    issue = done_issue_with_mr(mr_iid: 44)
    client = StubClient.new(mr_state: 'merged')

    verdict = build_router.route(FakeGlIssue.new(issue.issue_iid, 'fake title'), client)

    assert_equal :next, verdict
    issue.reload

    # Stays in done — no AASM transition, no reimplementation cycle.
    assert_equal 'done', issue.status
    # But we still poked GitLab labels to strip todo and re-apply done.
    refute_empty client.label_calls
  end

  # --- the reentry decision is a read, not a guess (Autodev #67) -----------
  #
  # `reenter_destination` used to answer an unreadable MR state with
  # `:reimplementation` — and that is the most expensive branch there is: full
  # clone, danger-claude, push, on a ticket whose MR may already be merged. Same
  # shape as the four readers #62 unpicked, and the same reason it was invisible:
  # `:reimplementation` is a perfectly plausible destination.
  #
  # `route` is the boundary. One issue's routing is the unit of work, so a read
  # that failed skips *that* issue for this cycle and `dispatch_new_issues` keeps
  # going through the rest of the population.

  def test_an_unreadable_mr_state_does_not_trigger_a_reimplementation
    issue = done_issue_with_mr(mr_iid: 42)
    client = StubClient.new(mr_state: 'opened', mr_error: api_error)

    verdict = build_router.route(FakeGlIssue.new(issue.issue_iid, 'fake title'), client)

    assert_equal :next, verdict
    assert_equal 'done', issue.reload.status, 'an unread MR state must not decide the reentry path'
    assert_empty client.label_calls, 'nothing may be announced about a reentry that did not happen'
  end

  # The recette-KO question (bug #32) is answered by an `issue_notes` read whose
  # `false` used to mean "nobody replied". That is a verdict: it routes to
  # `:pipeline_check`, which never reads issue comments, so the identical MR is
  # re-delivered and the human's feedback is never seen.
  def test_an_unreadable_issue_comment_history_does_not_decide_the_reentry_path
    issue = done_issue_with_mr(mr_iid: 42)
    issue.update(finished_at: Time.parse('2026-07-01T10:00:00Z'))
    client = StubClient.new(mr_state: 'opened', notes_error: api_error)

    verdict = build_router.route(FakeGlIssue.new(issue.issue_iid, 'fake title'), client)

    assert_equal :next, verdict
    assert_equal 'done', issue.reload.status
  end

  # `locked` is GitLab's transient state while a merge is in flight: the MR may
  # well be `merged` a second later. Routing it to `:reimplementation` — which the
  # `else` branch did — clones, re-implements and pushes over work that is about
  # to land in the target branch. Nothing is concluded; the next cycle re-reads.
  def test_a_locked_mr_waits_for_the_next_cycle
    issue = done_issue_with_mr(mr_iid: 42)
    client = StubClient.new(mr_state: 'locked')

    verdict = build_router.route(FakeGlIssue.new(issue.issue_iid, 'fake title'), client)

    assert_equal :next, verdict
    assert_equal 'done', issue.reload.status
    assert_empty client.label_calls, 'the todo label must stay on, so the next cycle re-asks'
  end

  # Control: `:reimplementation` is kept for a state that really is unknown.
  def test_an_unknown_mr_state_still_reimplements
    issue = done_issue_with_mr(mr_iid: 42)
    client = StubClient.new(mr_state: 'something_gitlab_added_later')

    build_router.route(FakeGlIssue.new(issue.issue_iid, 'fake title'), client)

    assert_equal 'pending', issue.reload.status
  end

  # --- reentry from `closed` (Autodev #52) ---------------------------
  #
  # A stop decided by a human now ends in `closed` rather than `done`, so the
  # documented loop — repose the todo label, reassign autodev — has to keep
  # working from there or the stop becomes a trap. What keeps that safe is the
  # threshold: only a todo label applied *after* the row was closed counts.

  def closed_issue_with_mr(mr_iid:, finished_at: Time.parse('2026-07-01T10:00:00Z'))
    issue = done_issue_with_mr(mr_iid: mr_iid)
    issue.close!
    issue.update(finished_at: finished_at)
    issue
  end

  def todo_event(at)
    FakeLabelEvent.new('add', FakeLabel.new('To do'), at)
  end

  def test_a_closed_row_reenters_when_the_todo_label_was_reapplied_after_the_stop
    issue = closed_issue_with_mr(mr_iid: 42)
    client = StubClient.new(mr_state: 'opened', label_events: [todo_event('2026-07-02T09:00:00Z')])

    build_router.route(FakeGlIssue.new(issue.issue_iid, 'fake title'), client)

    assert_equal 'checking_pipeline', issue.reload.status
  end

  def test_a_closed_row_without_an_mr_reenters_to_pending
    issue = closed_issue_with_mr(mr_iid: nil)
    client = StubClient.new(mr_state: 'opened', label_events: [todo_event('2026-07-02T09:00:00Z')])

    build_router.route(FakeGlIssue.new(issue.issue_iid, 'fake title'), client)

    assert_equal 'pending', issue.reload.status
  end

  # The dashboard close button stays an off-switch: the todo label was already
  # on the ticket when the operator clicked, so nothing new was asked.
  def test_a_closed_row_whose_todo_label_predates_the_close_stays_closed
    issue = closed_issue_with_mr(mr_iid: 42)
    client = StubClient.new(mr_state: 'opened', label_events: [todo_event('2026-06-30T09:00:00Z')])

    verdict = build_router.route(FakeGlIssue.new(issue.issue_iid, 'fake title'), client)

    assert_equal :next, verdict
    assert_equal 'closed', issue.reload.status
  end

  def test_a_closed_row_with_no_label_events_stays_closed
    issue = closed_issue_with_mr(mr_iid: 42)

    build_router.route(FakeGlIssue.new(issue.issue_iid, 'fake title'),
                       StubClient.new(mr_state: 'opened'))

    assert_equal 'closed', issue.reload.status
  end

  # A `done` row must not pay for the new question.
  def test_a_done_row_costs_no_label_event_read
    issue = done_issue_with_mr(mr_iid: 42)
    client = StubClient.new(mr_state: 'opened')

    build_router.route(FakeGlIssue.new(issue.issue_iid, 'fake title'), client)

    assert_equal 0, client.label_event_calls
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

# The *other* caller of the read the reentry decision above depends on, tested
# here so the two answers to "GitLab did not answer the issue_notes read" sit
# next to each other (Autodev #67).
#
# `human_comment_since?` no longer answers `false` for an outage, so this caller
# declares its own boundary — and the answer is different from the router's, on
# purpose. `false` here means the row stays in `needs_clarification` and
# `dispatch_new_issues` re-asks GitLab the same question next cycle: nothing is
# concluded and nothing acts. In `open_mr_destination` the same `false` chose a
# route and re-delivered an MR.
class ClarificationCheckBoundaryTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_CONFIG = { 'path' => 'group/project', 'labels_todo' => ['To do'] }.freeze
  FakeGlIssue = Struct.new(:iid)
  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  class StubClient
    def issue_notes(_path, _iid, **_opts)
      response = FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/x'))
      raise Gitlab::Error::ResponseError, response
    end
  end

  def setup = setup_database

  def test_an_unreadable_comment_history_leaves_the_row_waiting_for_clarification
    issue = create_issue(status: 'needs_clarification',
                         clarification_requested_at: Time.parse('2026-07-01T10:00:00Z'))
    dispatcher = Autodev::PollDispatcher.allocate
    { path: PROJECT_CONFIG['path'], project_config: PROJECT_CONFIG, config: {},
      logger: StubLogger.new, client: StubClient.new }
      .each { |name, value| dispatcher.instance_variable_set(:"@#{name}", value) }

    refute dispatcher.send(:clarification_received?, issue, FakeGlIssue.new(issue.issue_iid))
    assert_equal 'needs_clarification', issue.reload.status
  end
end

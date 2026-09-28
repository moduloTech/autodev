# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/activity_logger'
require 'autodev/poll_router'

# `dormant_recheck_count` is a budget like the others (Autodev #125, D3).
#
# A#139, A#144 and A#148 sit at 3/3 in production. Neither the label resume nor
# the Reset button touched the counter, although both give back every other
# budget (`retry_count`, `review_failure_count`, the fix rounds, and the sibling
# `infra_recheck_count`) — so whatever a human does, their next dormant episode
# ends in `dormant_exhausted` without the audit looking at them once.
#
# The counter is reset by those two gestures and by nothing else. The cap exists
# so a row that keeps falling dormant stops consuming GitLab reads (#47, #103):
# an automatic recovery that reset it would reopen that loop, so the half of
# this file that asserts nothing moves is as much the contract as the half that
# asserts a reset.
class AResumeRestoresTheDormantBudgetTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_CONFIG = { 'path' => 'group/project', 'max_retries' => 1,
                     'labels_todo' => ['To do'], 'label_doing' => 'Doing',
                     'label_done' => 'Done', 'label_attention' => 'Attention' }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example',
             'poll_interval' => 300 }.freeze
  AUTODEV_ID = 7
  AUTHOR_ID = 42
  MR_IID = 42
  SPENT = { dormant_recheck_count: 3 }.freeze

  FakeGlIssue = Struct.new(:iid, :title)
  FakeAssignee = Struct.new(:id, :username)
  FakeMr = Struct.new(:state)
  FakeIssue = Struct.new(:state, :labels, :assignees)
  FakeNote = Struct.new(:id, :body)
  Paginated = Struct.new(:rows) { def auto_paginate = rows }

  # Stateful enough for the reclaim's read-back and for the audit's three
  # questions: a write to labels or assignees is what the next read answers.
  class StubClient
    def initialize(mr_state: 'opened', assignee_ids: [AUTODEV_ID], labels: ['Doing'])
      @mr_state = mr_state
      @assignees = assignee_ids.map { |id| FakeAssignee.new(id, "user#{id}") }
      @labels = labels.dup
    end

    def user = FakeAssignee.new(AUTODEV_ID, 'autodev')
    def merge_request(_project, _iid) = FakeMr.new(@mr_state)
    def issue(_project, _iid) = FakeIssue.new('opened', @labels.dup, @assignees.dup)
    def issue_notes(_project, _iid, **) = Paginated.new([])
    def merge_request_notes(_project, _iid, **) = Paginated.new([])
    def issue_label_events(_project, _iid) = Gitlab::PaginatedResponse.new([])
    def create_issue_note(_project, _iid, body) = FakeNote.new(1, body)
    def issue_note(_project, _iid, note_id) = FakeNote.new(note_id, '')
    def edit_issue_note(_project, _iid, note_id, body) = FakeNote.new(note_id, body)

    def edit_issue(_project, _iid, **opts)
      @labels = opts[:labels].to_s.split(',') if opts.key?(:labels)
      return unless opts.key?(:assignee_ids)

      @assignees = Array(opts[:assignee_ids]).compact.first(1).map { |id| FakeAssignee.new(id, "user#{id}") }
    end
  end

  # The reimplementation path hands the row to a worker; what the worker does is
  # not this file's question, so the block is recorded and never run.
  class RecordingPool
    attr_reader :enqueued

    def initialize = @enqueued = []

    def enqueue?(issue_iid:)
      @enqueued << issue_iid
      true
    end
  end

  def setup
    setup_database
    @logger = StubLogger.new
    GitlabHelpers.instance_variable_set(:@current_user_id, AUTODEV_ID)
  end

  def router(pool: nil)
    PollRouter.new(config: CONFIG, project_config: PROJECT_CONFIG, logger: @logger, token: 'x', pool: pool)
  end

  def dormant_pair(issue) = issue.reload.then { [it.dormant_recheck_count, it.dormant_recheck_at] }

  def audit
    Autodev::DormantAudit.new(client: StubClient.new, path: PROJECT_CONFIG['path'], config: CONFIG,
                              project_config: PROJECT_CONFIG, logger: @logger)
  end

  def spent_row(overrides = {})
    create_issue(SPENT.merge(dormant_recheck_at: 1.day.from_now).merge(overrides))
  end

  # --- 1. the A#139 replay: the Reset button --------------------------------

  def test_a_reset_with_its_budget_gives_the_dormant_pair_back_on_both_halves
    with_mr = spent_row(status: 'error', mr_iid: MR_IID)
    without = spent_row(status: 'error', mr_iid: nil)

    Issue.reset_for_retry!(Issue.where(id: [with_mr.id, without.id]), reset_budget: true)

    assert_equal [0, nil], dormant_pair(with_mr), 'the MR half kept its spent dormant budget'
    assert_equal [0, nil], dormant_pair(without), 'the pre-MR half kept its spent dormant budget'
  end

  # The end-to-end half of the replay: after the reset, the next time both rows
  # fall dormant the audit looks at them instead of declaring them exhausted.
  def test_a_reset_row_that_falls_dormant_again_is_audited_again
    ids = [spent_row(status: 'error', mr_iid: MR_IID), spent_row(status: 'error', mr_iid: nil)].map(&:id)
    Issue.reset_for_retry!(Issue.where(id: ids), reset_budget: true)
    Issue.where(id: ids).update_all(status: 'error', next_retry_at: nil, created_at: 2.hours.ago)

    assert_equal ids.sort, audit.candidates.map(&:id).sort, 'a reset row was not audited when it fell dormant again'
  end

  # --- 2. a reset without its budget ----------------------------------------

  def test_a_reset_without_its_budget_leaves_the_dormant_pair_alone
    at = 1.day.from_now.change(usec: 0)
    with_mr = spent_row(status: 'error', mr_iid: MR_IID, dormant_recheck_at: at)
    without = spent_row(status: 'error', mr_iid: nil, dormant_recheck_at: at)

    Issue.reset_for_retry!(Issue.where(id: [with_mr.id, without.id]))

    assert_equal [3, at], dormant_pair(with_mr)
    assert_equal [3, at], dormant_pair(without)
  end

  # --- 3. the label resume --------------------------------------------------

  def finished_row(overrides = {})
    spent_row({ status: 'done', issue_author_id: AUTHOR_ID, locale: 'fr', review_count: 1 }.merge(overrides))
  end

  def test_the_label_resume_through_a_reimplementation_resets_the_dormant_pair
    issue = finished_row(mr_iid: nil)
    pool = RecordingPool.new

    router(pool: pool).route(FakeGlIssue.new(issue.issue_iid, 'a request'), StubClient.new)

    assert_equal 'pending', issue.reload.status
    assert_equal [issue.issue_iid], pool.enqueued
    assert_equal [0, nil], dormant_pair(issue)
  end

  def test_the_label_resume_through_the_pipeline_check_resets_the_dormant_pair
    issue = finished_row(mr_iid: MR_IID)

    router.route(FakeGlIssue.new(issue.issue_iid, 'a request'), StubClient.new)

    assert_equal 'checking_pipeline', issue.reload.status
    assert_equal [0, nil], dormant_pair(issue)
  end

  # --- 4. the automatic paths keep it ---------------------------------------

  def test_an_infra_recovery_keeps_the_dormant_count
    issue = finished_row(mr_iid: MR_IID, dormant_recheck_count: 2, needs_attention: true,
                         attention_reason: 'stagnation_pipeline')

    router.resume_recovered_infra(issue, StubClient.new(assignee_ids: [AUTHOR_ID], labels: []))

    assert_equal 'checking_pipeline', issue.reload.status
    assert_equal 2, issue.dormant_recheck_count
  end

  def test_the_review_arrears_sweep_keeps_the_dormant_count
    issue = finished_row(mr_iid: MR_IID, dormant_recheck_count: 2, review_count: 0)

    router.resume_never_reviewed(issue, StubClient.new)

    assert_equal 'checking_pipeline', issue.reload.status
    assert_equal 2, issue.dormant_recheck_count
  end

  # --- 5. DormantAudit's own revive keeps it --------------------------------
  #
  # `revive_stalled!` calls `reset_for_retry!` for its pre-MR half, without
  # `reset_budget:` — which is the only thing standing between the audit and a
  # counter it resets itself on every successful revive.

  def test_a_revived_pre_mr_row_keeps_the_attempt_it_just_spent
    issue = create_issue(status: 'implementing', mr_iid: nil, created_at: 4.hours.ago)

    audit.run

    assert_equal 'pending', issue.reload.status
    assert_equal 1, issue.dormant_recheck_count
  end

  def test_a_revived_post_mr_row_keeps_the_attempt_it_just_spent
    issue = create_issue(status: 'implementing', mr_iid: MR_IID, created_at: 4.hours.ago)

    audit.run

    assert_equal 'checking_pipeline', issue.reload.status
    assert_equal 1, issue.dormant_recheck_count
  end
end

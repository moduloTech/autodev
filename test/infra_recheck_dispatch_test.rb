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
#   3. Autodev #93/#106: every `stagnation_pipeline` row reached `done` through
#      `abandon_issue`, which hands the ticket back to a human — so the recheck
#      must reclaim the assignment before re-entering, or the row is found
#      unassigned and falsely closed at the next `dispatch_unassignment` sweep.
class InfraRecheckDispatchTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  include DatabaseTestHelper

  PROJECT_CONFIG = {
    'path' => 'group/project',
    'labels_todo' => ['To do'],
    'label_doing' => 'Doing',
    'label_done' => 'Done',
    'label_attention' => 'Attention'
  }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example' }.freeze

  AUTODEV_ID = 7
  AUTHOR_ID = 42

  FakeMr = Struct.new(:state)
  FakeGlIssue = Struct.new(:iid, :title)
  FakeAssignee = Struct.new(:id, :username)
  FakeIssue = Struct.new(:labels, :assignees, :state) do
    def initialize(labels, assignees, state = 'opened') = super
  end

  # Stateful stub: a write is visible to the next read, which is what makes
  # the reclaim's read-back (and the regression's "not closed next cycle"
  # assertion) testable at all. Mirrors ReviewArrearsSweepTest::StubClient.
  class StubClient
    attr_reader :edits, :notes

    def initialize(assignee_ids: [AUTHOR_ID], labels: [], issue_notes: [], mr_notes: [],
                   label_events: [])
      @labels = labels.dup
      @assignees = assignee_ids.map { |id| FakeAssignee.new(id, "user#{id}") }
      @edits = []
      @notes = []
      @issue_notes = issue_notes
      @mr_notes = mr_notes
      @label_events = label_events
    end

    def user = FakeAssignee.new(AUTODEV_ID, 'autodev')
    def merge_request(_project, _iid) = FakeMr.new('opened')
    def issue(_project, _iid) = FakeIssue.new(@labels.dup, @assignees.dup)

    def edit_issue(_project, _iid, **opts)
      @edits << opts
      @labels = opts[:labels].to_s.split(',') if opts.key?(:labels)
      return unless opts.key?(:assignee_ids)

      # GitLab Community: one assignee per issue, so a list of more than one
      # is accepted and only the first survives (Autodev #98).
      @assignees = Array(opts[:assignee_ids]).compact.first(1).map { |id| FakeAssignee.new(id, "user#{id}") }
    end

    def create_issue_note(_project, _iid, body)
      @notes << body
      Struct.new(:id).new(123)
    end

    def assignee_ids = @assignees.map(&:id)

    # Autodev #93/#106 + alpha-53 review G2: the reclaim is now gated on
    # `UntouchedSinceGiveup`, which asks the ticket's notes, the merge
    # request's notes and the workflow label. `human_comment_since?` goes
    # through `.auto_paginate`, so the stub answers a paginated-looking list.
    def issue_notes(_project, _iid, **) = Paginated.new(@issue_notes)
    def merge_request_notes(_project, _iid, **) = Paginated.new(@mr_notes)

    # `LabelHandover#moved_since?` reads the label events whenever the current
    # labels look suspicious, and an issue carrying no `label_doing` is the
    # weakest of its three signals (`doing_removed`) — so this is reached on
    # an ordinary re-arm, not only on a handover. No event means nobody moved
    # anything, which is what an untouched row looks like.
    def issue_label_events(_project, _iid) = @label_events
  end

  # Minimal stand-in for `Gitlab::PaginatedResponse`.
  Paginated = Struct.new(:rows) do
    def auto_paginate = rows
  end

  FakeNote = Struct.new(:system, :created_at, :body)

  def human_note(at:, body: 'I have this one, fixing the CI myself')
    FakeNote.new(system: false, created_at: at, body: body)
  end

  # Models Community silently ignoring an assignee write it cannot honour
  # (Autodev #98): the edit call succeeds (no exception) but changes nothing.
  class SilentlyIgnoringClient < StubClient
    def edit_issue(_project, _iid, **opts)
      @edits << opts
      @labels = opts[:labels].to_s.split(',') if opts.key?(:labels)
    end
  end

  # Minimal `Autodev::ExternalState` includer, mirroring `ExternalStateTest::Host` —
  # used to replay `PollDispatcher#check_external_state`'s three questions
  # without building a whole dispatcher (and its own GitLab client).
  class ExternalStateHost
    include Autodev::ExternalState

    def initialize(client, logger)
      @client = client
      @path = PROJECT_CONFIG['path']
      @project_config = PROJECT_CONFIG
      @logger = logger
    end
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

  def resumed(issue, client = StubClient.new)
    GitlabHelpers.stub(:current_user_id, AUTODEV_ID) { build_router.resume_recovered_infra(issue, client) }
    client
  end

  def test_resume_recovered_infra_reenters_checking_pipeline_and_clears_attention
    issue = infra_stagnation_issue(review_count: 3, infra_recheck_count: 2)

    resumed(issue)
    issue.reload

    assert_equal 'checking_pipeline', issue.status
    assert_nil issue.attention_reason
    refute issue.needs_attention
  end

  def test_resume_recovered_infra_caps_review_count_at_one
    issue = infra_stagnation_issue(review_count: 3)

    resumed(issue)

    assert_equal 1, issue.reload.review_count
  end

  # Autodev #85. This pass is the *automatic* caller of the shared reentry —
  # nobody reposes a label, nobody looks — and its population is a pipeline
  # stagnation, which is overwhelmingly a request that stalled before any review
  # ran. `infra_stagnation_issue` creates `review_count = 0` by default and no
  # test here asserted the counter on such a row: writing 1 over the 0 made the
  # first green pipeline after recovery skip the review and finish the request
  # under `label_done`.
  def test_resume_recovered_infra_does_not_invent_a_review_on_a_never_reviewed_row
    issue = infra_stagnation_issue(review_count: 0)

    resumed(issue)

    assert_equal 0, issue.reload.review_count,
                 'the automatic infra recheck re-armed a never-reviewed request as if it had been reviewed'
  end

  # -- reclaim (Autodev #93/#106) --

  def test_resume_recovered_infra_reclaims_the_assignment
    issue = infra_stagnation_issue
    client = resumed(issue)

    assert_equal [AUTODEV_ID], client.assignee_ids
  end

  def test_resume_recovered_infra_records_the_displaced_assignee
    issue = infra_stagnation_issue

    resumed(issue)

    assert_equal AUTHOR_ID, issue.reload.displaced_assignee_id
  end

  def test_resume_recovered_infra_announces_the_reclaim_by_name
    issue = infra_stagnation_issue
    client = resumed(issue)

    reclaim_notes = client.notes.select { |body| body.include?('je reprends ce ticket') }

    assert_equal 1, reclaim_notes.size
    assert_includes reclaim_notes.first, "@user#{AUTHOR_ID}"
  end

  def test_resume_recovered_infra_reposes_the_label_without_clearing_scope
    issue = infra_stagnation_issue
    client = StubClient.new(labels: ['PM::Evolution'])

    resumed(issue, client)

    assert_includes client.issue(PROJECT_CONFIG['path'], issue.issue_iid).labels, 'PM::Evolution',
                    'clear_scope must stay off this path (design §3) — only the sweep has asked ' \
                    'untouched_since_giveup? before it writes'
  end

  # -- the human-activity gate (alpha-53 neutral review, G2) ---------------
  #
  # `fetch_infra_recheck_candidates` asks nothing about what a person did — it
  # filters on status, flag, reason, MR and clocks. Since Autodev #93/#106 this
  # path *takes the ticket*, so re-arming a row a human picked back up removes
  # their assignment (GitLab Community: one assignee) and tells them on their
  # own ticket that the CI recovered. `UntouchedSinceGiveup` is the sweep's own
  # protection, and the infra pass has to ask it too.

  def test_a_row_a_human_commented_on_since_the_giveup_is_not_reclaimed
    issue = infra_stagnation_issue(finished_at: 2.hours.ago)
    client = StubClient.new(issue_notes: [human_note(at: 1.hour.ago)])

    resumed(issue, client)

    assert_equal [AUTHOR_ID], client.assignee_ids, "the human's assignment must survive"
    assert_empty client.notes, 'nothing may be posted on a ticket a human has taken back'
  end

  def test_a_row_a_human_commented_on_since_the_giveup_is_not_transitioned
    issue = infra_stagnation_issue(finished_at: 2.hours.ago)

    resumed(issue, StubClient.new(issue_notes: [human_note(at: 1.hour.ago)]))

    refute_equal 'checking_pipeline', issue.reload.status, 'a row a human holds must not be re-armed'
    assert issue.needs_attention, 'the give-up flag must stay up'
  end

  def test_a_row_a_human_commented_on_since_the_giveup_keeps_its_giveup_label
    issue = infra_stagnation_issue(finished_at: 2.hours.ago)
    client = StubClient.new(labels: [PROJECT_CONFIG['label_attention']],
                            issue_notes: [human_note(at: 1.hour.ago)])

    resumed(issue, client)

    labels = client.issue(PROJECT_CONFIG['path'], issue.issue_iid).labels

    refute_includes labels, PROJECT_CONFIG['label_doing'],
                    'no working label may be posed on a ticket a human has taken back'
  end

  def test_a_human_comment_on_the_merge_request_also_blocks_the_reclaim
    # Autodev #98's lesson: reviewing the merge request is the gesture a
    # reviewer actually makes, and it used to be invisible to this question.
    issue = infra_stagnation_issue(finished_at: 2.hours.ago)
    client = StubClient.new(mr_notes: [human_note(at: 1.hour.ago, body: 'left you two comments')])

    resumed(issue, client)

    assert_equal [AUTHOR_ID], client.assignee_ids
    refute_equal 'checking_pipeline', issue.reload.status
  end

  def test_autodevs_own_comment_after_the_giveup_does_not_block_the_reclaim
    # The give-up comment itself is autodev's, posted at `finished_at` or just
    # after. Reading it as human activity would freeze every abandoned row.
    issue = infra_stagnation_issue(finished_at: 2.hours.ago)
    own = FakeNote.new(system: false, created_at: 1.hour.ago,
                       body: ':stop_sign: **autodev** : abandon sur stagnation de pipeline')
    client = StubClient.new(issue_notes: [own])

    resumed(issue, client)

    assert_equal [AUTODEV_ID], client.assignee_ids, "autodev's own note must not count as a human's"
    assert_equal 'checking_pipeline', issue.reload.status
  end

  def test_a_comment_predating_the_giveup_does_not_block_the_reclaim
    issue = infra_stagnation_issue(finished_at: 1.hour.ago)
    client = StubClient.new(issue_notes: [human_note(at: 3.hours.ago)])

    resumed(issue, client)

    assert_equal [AUTODEV_ID], client.assignee_ids, 'only activity *since* the give-up counts'
  end

  # A read GitLab accepted and then silently ignored (Community edition: one
  # assignee per issue) must not be read as a landed reclaim.
  def test_resume_recovered_infra_leaves_the_row_untransitioned_when_the_assignment_does_not_land
    issue = infra_stagnation_issue
    client = resumed(issue, SilentlyIgnoringClient.new)

    refute_equal 'checking_pipeline', issue.reload.status, 'a reclaim that did not land must not be transitioned'
    assert issue.needs_attention
    refute_includes client.issue(PROJECT_CONFIG['path'], issue.issue_iid).labels, PROJECT_CONFIG['label_doing'],
                    'the label must be put back when the assignment could not be landed'
  end

  # Regression (design's Testing section, path 1 of 2, Autodev #93/#106): a row
  # abandoned on pipeline stagnation whose infrastructure recovers must not be
  # found unassigned and closed at the next cycle, with a false "autodev was
  # unassigned" comment posted on the client's ticket.
  def test_a_recovered_row_is_not_closed_as_unassigned_at_the_next_cycle
    issue = infra_stagnation_issue
    client = resumed(issue)
    issue.reload

    assert_equal 'checking_pipeline', issue.status, 'precondition: the row re-entered'

    sweep_dispatch_unassignment(issue, client)
    issue.reload

    refute_equal 'closed', issue.status
    assert_empty client.notes.grep(/j'arrete le travail en cours/),
                 'a false "unassigned" comment was posted on the client ticket'
  end

  private

  # `PollDispatcher#check_external_state`'s own three questions, replayed
  # directly against `Autodev::ExternalState` so this test does not have to
  # build a whole dispatcher (and its own GitLab client) just to ask them.
  def sweep_dispatch_unassignment(issue, client)
    host = ExternalStateHost.new(client, @logger)
    gl_issue = client.issue(PROJECT_CONFIG['path'], issue.issue_iid)
    GitlabHelpers.stub(:current_user_id, AUTODEV_ID) do
      return host.close_externally(issue) if host.externally_closed?(gl_issue)
      return host.stop_unassigned(issue) unless host.assigned_to_autodev?(gl_issue)

      host.stop_on_handover(issue, gl_issue)
    end
  end

  def build_router
    PollRouter.new(config: CONFIG, project_config: PROJECT_CONFIG,
                   logger: @logger, token: 'x', pool: nil)
  end
end

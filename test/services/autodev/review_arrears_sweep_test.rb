# frozen_string_literal: true

require_relative '../../test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/danger_claude_runner'
require 'autodev/issue_notifier'
require 'autodev/label_manager'
require 'autodev/activity_logger'
require 'autodev/issue_processor'
require 'autodev/poll_router'
require 'stringio'

# Autodev #88 — the arrears of the revoked review token.
#
# 23 PowerPanne requests were given up between the 30/07 and the 14/08/2026 under
# `review_failures_exhausted`, all of them with `review_count` still at 0: not one
# was ever reviewed. Nothing brings them back. `dispatch_infra_recheck` selects
# `stagnation_pipeline` and deliberately excludes every other give-up reason
# (Autodev #53: an abandon is not re-armed automatically), the Autodev #75 sweep
# is written for `needs_clarification`, and 22 of the 23 tickets are assigned to a
# human, so `dispatch_new_issues`' `assignee_id: <autodev>` filter cannot see a
# label somebody reposes on them either.
#
# So this is a one-shot rake, like `ClarificationSweep` and
# `ActivityEventCompaction`, and it is bounded three ways: an explicit `APPLY=1`,
# a per-run `LIMIT` (3, `max_workers`), and an ownership filter that is strict
# unless the operator writes `INCLUDE_AUTHOR_HANDBACK=1`.
#
# ClassLength: one class per sweep with the fixtures its halves share, the same
# shape as `ClarificationSweepTest`.
class ReviewArrearsSweepTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  include DatabaseTestHelper

  PATH = 'group/arrears'
  OTHER_PATH = 'group/arrears-two'
  # Powerpanne's own shape: the three labels autodev writes share one GitLab
  # scope, which is what makes `LabelHandover`'s `workflow_moved` rule live.
  DOING = 'Development::Doing'
  ATTENTION = 'Development::StandBy'
  MOVED_ON = 'Development::Awaiting CR'
  PROJECT = { 'path' => PATH, 'labels_todo' => ['To do'], 'label_doing' => DOING,
              'label_done' => 'Development::Awaiting Feature Review',
              'label_attention' => ATTENTION }.freeze
  OTHER_PROJECT = PROJECT.merge('path' => OTHER_PATH).freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example',
             'projects' => [PROJECT, OTHER_PROJECT] }.freeze

  AUTODEV_USER_ID = 7
  AUTHOR_ID = 42
  OTHER_HUMAN_ID = 99
  GIVEN_UP_AT = Time.parse('2026-08-05T09:00:00Z')

  FakeMr = Struct.new(:state, :detailed_merge_status, :has_conflicts)
  FakeGlIssue = Struct.new(:state, :assignees, :labels)
  FakeAssignee = Struct.new(:id, :username)
  FakeNote = Struct.new(:system, :created_at, :body)
  FakeLabel = Struct.new(:name)
  FakeUser = Struct.new(:id)
  FakeLabelEvent = Struct.new(:action, :label, :created_at, :user)

  Paginated = Struct.new(:items) do
    def auto_paginate = items
  end

  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  # Everything the sweep may touch on GitLab, with per-iid overrides so one
  # client can serve a multi-row population — which is the shape production has.
  #
  # It **keeps state**: a write is visible to the next read. That is what makes
  # the verification the sweep performs after its writes testable at all, and two
  # GitLab **Community** behaviours are modelled on purpose, because both of them
  # are what the sweep gets wrong when it assumes Premium (Autodev #98):
  #
  #   * a `labels=` write replaces the whole list and GitLab keeps it exactly as
  #     sent — there is NO one-value-per-scope rule, so `Development::Awaiting CR`
  #     survives beside a `Development::Doing` posed next to it unless autodev
  #     removes it itself;
  #   * `assignee_ids:` holds ONE assignee, so a list of two is accepted and only
  #     the first survives.
  #
  # `label_error_iids` / `assignee_error_iids` fail one write and nothing else:
  # `LabelManager#manage_labels` answers a GitLab error with `[]`, so the failed
  # label write is silent by construction and only the read-back finds it.
  class StubClient
    attr_reader :edits, :created_notes

    def initialize(**opts)
      @opts = opts
      @edits = []
      @created_notes = []
      @issues = {}
    end

    def issue(_path, iid)
      raise Gitlab::Error::ResponseError, response if Array(@opts[:issue_error_iids]).include?(iid)

      stored(iid)
    end

    def merge_request(_path, iid)
      raise Gitlab::Error::ResponseError, response if Array(@opts[:mr_error_iids]).include?(iid)

      (@opts[:mrs] || {})[iid] || @opts[:mr] || ReviewArrearsSweepTest.open_mr
    end

    def issue_notes(_path, _iid, **_opts) = Paginated.new(Array(@opts[:notes]))
    def issue_label_events(_path, _iid) = Array(@opts[:label_events])
    def edit_issue_note(_path, _iid, _note_id, _body) = nil

    def edit_issue(path, iid, **opts)
      refuse_write(opts, iid)
      @edits << [path, iid, opts]
      apply_labels(iid, opts[:labels]) if opts.key?(:labels)
      apply_assignees(iid, opts[:assignee_ids]) if opts.key?(:assignee_ids)
      stored(iid)
    end

    def create_issue_note(path, iid, body)
      @created_notes << [path, iid, body]
      Struct.new(:id).new(1)
    end

    def label_edits = @edits.select { |_path, _iid, opts| opts.key?(:labels) }
    def assignee_edits = @edits.select { |_path, _iid, opts| opts.key?(:assignee_ids) }
    def labels_of(iid) = stored(iid).labels
    def assignees_of(iid) = Array(stored(iid).assignees).map(&:id)

    private

    # Materialised once per iid, and copied, so a write on one row of a
    # multi-row population is not a write on all of them.
    def stored(iid)
      @issues[iid] ||= copy((@opts[:gl_issues] || {})[iid] || @opts[:gl_issue] ||
                            ReviewArrearsSweepTest.default_gl_issue)
    end

    def copy(src) = FakeGlIssue.new(src.state, Array(src.assignees).dup, Array(src.labels).dup)

    def refuse_write(opts, iid)
      failing = { labels: :label_error_iids, assignee_ids: :assignee_error_iids }
                .any? { |key, option| opts.key?(key) && Array(@opts[option]).include?(iid) }
      raise Gitlab::Error::ResponseError, response if failing
    end

    # GitLab keeps the list exactly as it is sent. It does NOT enforce
    # one-value-per-scope on a `labels=` write: scoped-label exclusivity is a
    # Premium feature, source.modulotech.fr answers `enterprise: false`, and
    # powerpanne/core#11339 carries `Development::Awaiting CR` beside
    # `Development::Awaiting Feature Review` with no autodev involvement.
    #
    # This stub used to model the exclusivity, which made
    # `test_an_unconfigured_end_label_is_dropped_by_gitlabs_scope_exclusivity`
    # pass against a fiction on the exact mechanism the removal depended on
    # (Autodev #98).
    def apply_labels(iid, csv)
      stored(iid).labels = csv.to_s.split(',')
    end

    # GitLab Community holds ONE assignee per issue. `assignee_ids` with more
    # than one is accepted — 200, no exception — and only the first survives,
    # with no system note when that first one was already there. Multiple
    # assignees are Premium (Autodev #98).
    #
    # Measured on powerpanne/core#16224, 02/09/2026: the sweep wrote
    # `[human, autodev]`, GitLab kept `[human]`, `reclaim` reported success, and
    # `dispatch_unassignment` closed the row 94 seconds later with a comment
    # blaming the human for an unassignment nobody made.
    def apply_assignees(iid, ids)
      return if Array(@opts[:assignee_noop_iids]).include?(iid)

      stored(iid).assignees = Array(ids).compact.first(1).map { |id| FakeAssignee.new(id) }
    end

    def response = FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/x'))
  end

  def self.default_gl_issue = FakeGlIssue.new('opened', [FakeAssignee.new(AUTODEV_USER_ID)], [DOING])
  def self.open_mr = FakeMr.new('opened', 'mergeable', false)

  def setup
    setup_database
    @out = StringIO.new
  end

  # --- fixtures -------------------------------------------------------------

  def arrear(overrides = {})
    create_issue({ project_path: PATH, status: 'done', mr_iid: 500, needs_attention: true,
                   attention_reason: 'review_failures_exhausted', attention_detail: 'boom',
                   review_count: 0, review_failure_count: 5, issue_author_id: AUTHOR_ID,
                   finished_at: GIVEN_UP_AT }.merge(overrides))
  end

  def sweep(client, apply: false, limit: 3, include_author_handback: false, include_human_held: false)
    GitlabHelpers.stub(:build_gitlab_client, client) do
      GitlabHelpers.stub(:current_user_id, AUTODEV_USER_ID) do
        Autodev::ReviewArrearsSweep.new(config: CONFIG, apply: apply, limit: limit,
                                        include_author_handback: include_author_handback,
                                        include_human_held: include_human_held,
                                        out: @out).run
      end
    end
  end

  def rearmed_state(issue)
    issue.reload
    { status: issue.status, needs_attention: issue.needs_attention,
      attention_reason: issue.attention_reason, attention_detail: issue.attention_detail,
      review_failure_count: issue.review_failure_count, finished_at: issue.finished_at }
  end

  # --- 1. the population ----------------------------------------------------

  def test_a_request_given_up_before_any_review_is_examined
    arrear

    assert_equal 1, sweep(StubClient.new)[:examined]
  end

  # The whole point of the `review_count: 0` clause: a request that WAS reviewed
  # and lost its budget later is a different population, and the manual gesture
  # already took eight of them out. Nothing in the DB tells a skipped review from
  # a completed one once the counter has moved.
  def test_a_request_that_was_reviewed_once_is_out_of_the_population
    arrear(review_count: 1)

    assert_equal 0, sweep(StubClient.new)[:examined]
  end

  # Mirror of `test_only_a_pipeline_stagnation_is_ever_re_armed`: every other
  # give-up reason names a different cause and must never be re-armed from here.
  def test_only_an_exhausted_review_budget_is_ever_swept
    reasons = %w[review_failures_exhausted stagnation_pipeline stagnation_discussions
                 pipeline_watch_expired review_limit_reached dormant_exhausted
                 mr_closed_unmerged review_skill_missing]
    issues = reasons.to_h { |reason| [reason, arrear(attention_reason: reason)] }
    sweep(StubClient.new)

    assert_equal([issues['review_failures_exhausted'].issue_iid],
                 issues.values.map(&:issue_iid).select { |iid| @out.string.include?("##{iid} ") })
  end

  def test_a_row_that_is_not_flagged_is_out_of_the_population
    arrear(needs_attention: false)

    assert_equal 0, sweep(StubClient.new)[:examined]
  end

  def test_a_row_without_a_merge_request_is_out_of_the_population
    arrear(mr_iid: nil)

    assert_equal 0, sweep(StubClient.new)[:examined]
  end

  def test_a_row_that_is_not_done_is_out_of_the_population
    arrear(status: 'checking_pipeline')

    assert_equal 0, sweep(StubClient.new)[:examined]
  end

  # Same choice as Autodev #75: the population is what it is, not what was
  # investigated. No project filter.
  def test_every_project_is_swept
    one = arrear(project_path: PATH)
    two = arrear(project_path: OTHER_PATH)

    sweep(StubClient.new, apply: true)

    assert_equal %w[checking_pipeline checking_pipeline], [one.reload.status, two.reload.status]
  end

  # --- 2. reporting is the default ------------------------------------------

  def test_a_dry_run_changes_nothing
    issue = arrear
    client = StubClient.new

    sweep(client)

    assert_equal 'done', issue.reload.status
    assert_empty client.edits
    assert_empty client.created_notes
  end

  def test_a_dry_run_names_each_request_and_says_how_to_apply
    issue = arrear

    tally = sweep(StubClient.new)

    assert_equal 1, tally[:eligible]
    assert_includes @out.string, "#{PATH}##{issue.issue_iid}"
    assert_includes @out.string, 'APPLY=1'
  end

  # The MR facts travel to the operator, and none of them is a filter — the
  # conflicts included, and deliberately (Matthieu, 01/09/2026): resolving a
  # conflict is part of autodev's work, `RepoRebaser` already does it for any
  # merge request, and 12 of these 23 are in conflict.
  def test_the_report_carries_the_merge_request_facts
    arrear
    sweep(StubClient.new(mr: FakeMr.new('opened', 'conflict', true)))

    assert_includes @out.string, 'state opened, merge status conflict, conflicts yes'
  end

  # Which also means: the first row a default run re-arms is the one most likely
  # to reach a danger-claude conflict resolution and a force-push on a client
  # branch, at the correction round after the review.
  def test_a_conflicted_merge_request_is_still_eligible
    issue = arrear

    sweep(StubClient.new(mr: FakeMr.new('opened', 'conflict', true)), apply: true)

    assert_equal 'checking_pipeline', issue.reload.status
  end

  # `detailed_merge_status: "checking"` means GitLab has not finished computing,
  # so `has_conflicts: false` is not a fact there (Autodev #67 applied to a field).
  def test_a_merge_status_still_being_computed_reports_unknown_conflicts
    arrear
    sweep(StubClient.new(mr: FakeMr.new('opened', 'checking', false)))

    assert_includes @out.string, 'conflicts unknown'
  end

  # --- 3. APPLY -------------------------------------------------------------

  def test_apply_rearms_the_request
    issue = arrear

    sweep(StubClient.new, apply: true)

    assert_equal({ status: 'checking_pipeline', needs_attention: false, attention_reason: nil,
                   attention_detail: nil, review_failure_count: 0, finished_at: nil },
                 rearmed_state(issue))
  end

  # Autodev #85's guarantee, locked here too: this whole population exists
  # because nobody ever reviewed it, and a re-arm that wrote 1 would make the
  # next green pipeline skip the review and finish the request under `label_done`.
  def test_a_rearmed_request_still_carries_a_review_counter_of_zero
    issue = arrear

    sweep(StubClient.new, apply: true)

    assert_equal 0, issue.reload.review_count
  end

  def test_a_second_run_finds_nothing
    arrear
    client = StubClient.new
    sweep(client, apply: true)
    @out = StringIO.new

    assert_equal 0, sweep(client, apply: true)[:examined]
  end

  # --- 4. order and spread --------------------------------------------------

  # `.each` on an ordered scope, never `find_each`: Rails 8 discards a scope's
  # order inside `find_each`, forces primary-key order and only logs a warning.
  # Inserted out of order so the two orders disagree — this test is what breaks
  # if somebody swaps the one for the other (copy of Autodev #75's).
  def test_the_report_lists_the_oldest_give_up_first
    %w[2026-08-12 2026-07-30 2026-08-04].each_with_index do |day, i|
      arrear(issue_iid: 700 + i, finished_at: Time.parse("#{day}T10:00:00Z"))
    end
    sweep(StubClient.new)

    assert_equal %w[2026-07-30 2026-08-04 2026-08-12], @out.string.scan(/given up (\d{4}-\d{2}-\d{2})/).flatten
  end

  # 23 requests restarting on one cycle is the shape of the 11/08 incident. Three
  # is `max_workers`, so a batch never queues behind itself, and the manual re-run
  # IS the spacing — a human in the loop at every turn, which is what Autodev #53
  # asks of re-arming an abandon.
  def test_the_batch_is_capped_and_takes_the_oldest_first
    issues = (0..4).map { |i| arrear(issue_iid: 800 + i, finished_at: GIVEN_UP_AT + (i * 3600)) }

    tally = sweep(StubClient.new, apply: true, limit: 3)

    assert_equal [3, 2], [tally[:rearmed], tally[:deferred]]
    assert_equal(%w[checking_pipeline checking_pipeline checking_pipeline done done],
                 issues.map { |issue| issue.reload.status })
  end

  def test_the_report_says_how_many_eligible_requests_are_left_outside_the_batch
    (0..4).each { |i| arrear(issue_iid: 810 + i, finished_at: GIVEN_UP_AT + (i * 3600)) }

    sweep(StubClient.new, apply: true, limit: 3)

    assert_includes @out.string, 'deferred: 2'
  end

  # The report has no batch to protect: it must show the whole arrears so the
  # operator can count the runs.
  def test_the_cap_does_not_apply_to_a_report
    (0..4).each { |i| arrear(issue_iid: 820 + i, finished_at: GIVEN_UP_AT + (i * 3600)) }

    tally = sweep(StubClient.new, limit: 3)

    assert_equal [5, 0], [tally[:eligible], tally[:deferred]]
  end

  # A row nothing could be read about consumed no work, so it consumes no slot.
  def test_an_unreadable_row_does_not_consume_a_slot
    unreadable = arrear(issue_iid: 830, mr_iid: 900, finished_at: GIVEN_UP_AT)
    eligible = arrear(issue_iid: 831, mr_iid: 901, finished_at: GIVEN_UP_AT + 3600)

    sweep(StubClient.new(mr_error_iids: [900]), apply: true, limit: 1)

    assert_equal 'done', unreadable.reload.status
    assert_equal 'checking_pipeline', eligible.reload.status
  end

  # --- 5. the ownership filter ----------------------------------------------

  def test_a_ticket_assigned_to_another_human_is_never_rearmed
    issue = arrear
    client = StubClient.new(gl_issue: FakeGlIssue.new('opened', [FakeAssignee.new(OTHER_HUMAN_ID)], [DOING]))

    tally = sweep(client, apply: true, include_author_handback: true)

    assert_equal 'done', issue.reload.status
    assert_equal 1, tally[:not_ours]
    assert_empty client.edits
  end

  def test_a_ticket_closed_on_gitlab_is_never_rearmed
    issue = arrear
    closed = FakeGlIssue.new('closed', [FakeAssignee.new(AUTODEV_USER_ID)], [DOING])

    tally = sweep(StubClient.new(gl_issue: closed), apply: true)

    assert_equal 'done', issue.reload.status
    assert_equal 1, tally[:not_ours]
  end

  def test_a_ticket_still_assigned_to_autodev_is_eligible
    issue = arrear

    sweep(StubClient.new, apply: true)

    assert_equal 'checking_pipeline', issue.reload.status
  end

  # The permissive half, and it is always a written gesture: here the
  # unassignment is autodev's OWN write (`abandon_issue` → `hand_ticket_back`),
  # so the strict rule declines 22 of the 23 rows it was meant to rescue.
  #
  # It re-arms for real since Autodev #98, which is what the flag always claimed
  # and never did: the union write it relied on is ignored by GitLab Community,
  # so every row it accepted was transitioned unassigned and closed at the next
  # cycle. `reclaim` takes the ticket instead — announced, and recorded so the
  # handback finds its way back to the same person.
  def test_a_ticket_handed_back_to_its_author_is_eligible_behind_the_flag
    issue = arrear
    client = StubClient.new(gl_issue: FakeGlIssue.new('opened', [FakeAssignee.new(AUTHOR_ID)], [DOING]))

    tally = sweep(client, apply: true, include_author_handback: true)

    assert_equal 0, tally[:not_ours]
    assert_equal 1, tally[:rearmed]
    assert_equal 'checking_pipeline', issue.reload.status
  end

  # The widest tier, and the one the arrears actually need (Autodev #98): 4 of the
  # 20 rows are held by somebody who is not the author, so the tier above declines
  # them however untouched they are.
  def test_a_ticket_held_by_a_non_author_is_eligible_behind_the_widest_flag
    issue = arrear
    client = StubClient.new(gl_issue: FakeGlIssue.new('opened', [FakeAssignee.new(OTHER_HUMAN_ID)], [DOING]))

    tally = sweep(client, apply: true, include_human_held: true)

    assert_equal 1, tally[:rearmed]
    assert_equal 'checking_pipeline', issue.reload.status
    assert_equal OTHER_HUMAN_ID, issue.reload.displaced_assignee_id
  end

  # And the tier below still declines it, so the widening has to be written.
  def test_a_ticket_held_by_a_non_author_is_declined_by_the_author_flag
    issue = arrear
    client = StubClient.new(gl_issue: FakeGlIssue.new('opened', [FakeAssignee.new(OTHER_HUMAN_ID)], [DOING]))

    tally = sweep(client, apply: true, include_author_handback: true)

    assert_equal 1, tally[:not_ours]
    assert_equal 'done', issue.reload.status
  end

  # A person who touched the ticket since the give-up is working it, whoever they
  # are — that check survives every tier, and is why no username list is needed.
  def test_a_human_comment_since_the_give_up_declines_the_widest_flag_too
    issue = arrear
    client = StubClient.new(gl_issue: FakeGlIssue.new('opened', [FakeAssignee.new(OTHER_HUMAN_ID)], [DOING]),
                            notes: [FakeNote.new(false, '2026-08-06T10:00:00Z', 'On reprend a la main.')])

    tally = sweep(client, apply: true, include_human_held: true)

    assert_equal 1, tally[:not_ours]
    assert_equal 'done', issue.reload.status
  end

  def test_a_ticket_handed_back_to_its_author_is_declined_without_the_flag
    issue = arrear
    client = StubClient.new(gl_issue: FakeGlIssue.new('opened', [FakeAssignee.new(AUTHOR_ID)], [DOING]))

    tally = sweep(client, apply: true)

    assert_equal 'done', issue.reload.status
    assert_equal 1, tally[:not_ours]
  end

  def test_a_human_comment_since_the_give_up_declines_the_handback
    issue = arrear
    client = StubClient.new(gl_issue: FakeGlIssue.new('opened', [FakeAssignee.new(AUTHOR_ID)], [DOING]),
                            notes: [FakeNote.new(false, '2026-08-06T10:00:00Z', 'On reprend a la main.')])

    tally = sweep(client, apply: true, include_author_handback: true)

    assert_equal 'done', issue.reload.status
    assert_equal 1, tally[:not_ours]
  end

  def test_a_workflow_label_moved_by_somebody_else_declines_the_handback
    issue = arrear
    moved = FakeGlIssue.new('opened', [FakeAssignee.new(AUTHOR_ID)], [MOVED_ON])
    events = [FakeLabelEvent.new('add', FakeLabel.new(MOVED_ON), '2026-08-06T10:00:00Z',
                                 FakeUser.new(OTHER_HUMAN_ID))]
    client = StubClient.new(gl_issue: moved, label_events: events)

    tally = sweep(client, apply: true, include_author_handback: true)

    assert_equal 'done', issue.reload.status
    assert_equal 1, tally[:not_ours]
  end

  # --- 6. the state of the merge request ------------------------------------

  def test_a_merged_merge_request_is_named_and_left_alone
    issue = arrear
    client = StubClient.new(mr: FakeMr.new('merged', 'mergeable', false))

    tally = sweep(client, apply: true)

    assert_equal 1, tally[:already_merged]
    assert_equal 'done', issue.reload.status
    assert_empty client.edits
  end

  # Antedating an Autodev #66 verdict onto an Autodev #63 abandon would falsify
  # the audit trail: the reason column is not touched.
  def test_a_closed_merge_request_keeps_its_attention_reason
    issue = arrear
    client = StubClient.new(mr: FakeMr.new('closed', 'not_open', false))

    tally = sweep(client, apply: true)

    assert_equal 1, tally[:mr_closed]
    assert_equal 'review_failures_exhausted', issue.reload.attention_reason
    assert_empty client.edits
  end

  def test_a_transient_merge_request_waits_and_spends_nothing
    issue = arrear
    client = StubClient.new(mr: FakeMr.new('locked', nil, nil))

    tally = sweep(client, apply: true)

    assert_equal 1, tally[:waiting]
    assert_equal 'done', issue.reload.status
    assert_empty client.edits
  end

  # An allow-list, never a deny-list: a state GitLab adds tomorrow is unknown, and
  # unknown is "a human should look".
  def test_an_unknown_merge_request_state_is_named_and_left_alone
    issue = arrear
    client = StubClient.new(mr: FakeMr.new('something_gitlab_added_later', nil, nil))

    tally = sweep(client, apply: true)

    assert_equal 1, tally[:unknown_state]
    assert_equal 'done', issue.reload.status
  end

  def test_a_merge_request_that_cannot_be_read_leaves_the_row_intact
    issue = arrear

    tally = sweep(StubClient.new(mr_error_iids: [500]), apply: true)

    assert_equal 1, tally[:unreadable]
    assert_equal({ status: 'done', needs_attention: true,
                   attention_reason: 'review_failures_exhausted', attention_detail: 'boom',
                   review_failure_count: 5, finished_at: GIVEN_UP_AT }, rearmed_state(issue))
  end

  # `unreadable` is never a verdict: it is what makes a second run pick the row up.
  def test_an_outage_is_not_counted_as_a_verdict
    arrear

    tally = sweep(StubClient.new(issue_error_iids: [DatabaseTestHelper.iid_counter]), apply: true)

    assert_equal 1, tally[:unreadable]
    assert_equal [0, 0, 0], [tally[:not_ours], tally[:waiting], tally[:eligible]]
    assert_includes @out.string, 'a new run will pick it up'
  end

  def test_one_unreadable_row_does_not_stop_the_sweep
    unreadable = arrear(issue_iid: 840, mr_iid: 900)
    eligible = arrear(issue_iid: 841, mr_iid: 901)

    sweep(StubClient.new(mr_error_iids: [900]), apply: true)

    assert_equal 'done', unreadable.reload.status
    assert_equal 'checking_pipeline', eligible.reload.status
  end

  # --- 7. the mechanical consequences of re-arming --------------------------

  # Without this, `dispatch_unassignment` sweeps `checking_pipeline`, finds
  # autodev is not the assignee and CLOSES the row at the next cycle, with a
  # GitLab comment on a human's ticket. Autodev is *added* to the list, never
  # substituted for it — see section 11.
  #
  # The case that can actually satisfy the invariant on GitLab Community is the
  # row autodev still holds: the write is skipped because it would change
  # nothing, and the assignment is right for free. The human-held row is the one
  # the union was written for and it is the next test (Autodev #98).
  def test_a_rearmed_request_is_assigned_to_autodev
    issue = arrear
    client = StubClient.new

    sweep(client, apply: true)

    assert_includes client.assignees_of(issue.issue_iid), AUTODEV_USER_ID
    assert_equal 'checking_pipeline', issue.reload.status
  end

  # The assignment write is the one GitLab Community accepts and ignores, so an
  # exception is not what its failure looks like — the same shape `manage_labels`
  # has for labels, and the reason both are now read back.
  #
  # Measured on powerpanne/core#16224, 02/09/2026: the row transitioned with no
  # assignment event anywhere, and 94 seconds later `dispatch_unassignment`
  # closed it with a comment telling a human he had unassigned autodev. He had
  # not. The re-arm must stop instead, leaving the human on the ticket.
  def test_a_rearm_that_cannot_assign_autodev_does_not_transition
    issue = arrear
    client = StubClient.new(gl_issue: FakeGlIssue.new('opened', [FakeAssignee.new(AUTHOR_ID)], [DOING]),
                            assignee_noop_iids: [issue.issue_iid])

    tally = sweep(client, apply: true, include_author_handback: true)

    assert_equal 'done', issue.reload.status
    assert_equal 1, tally[:incomplete]
    assert_equal [AUTHOR_ID], client.assignees_of(issue.issue_iid)
  end

  # `apply_label_doing` is load-bearing, not decorative: without the working
  # label `stop_on_handover` reads a handover and closes the row. This case is
  # the configured one (`label_attention`, which `other_workflow_labels` names);
  # section 10 covers the one it does not.
  def test_rearming_strips_the_end_label
    arrear
    client = StubClient.new(gl_issue: FakeGlIssue.new('opened', [FakeAssignee.new(AUTODEV_USER_ID)],
                                                      [ATTENTION]))

    sweep(client, apply: true)

    assert_equal([[DOING]], client.label_edits.map { |_p, _i, opts| opts[:labels].split(',') })
  end

  # `manage_labels` skips a write that would change nothing, so the rows already
  # on `Doing` produce no resource label event — the record `LabelHandover` reads.
  def test_a_ticket_already_on_doing_produces_no_label_event
    arrear
    client = StubClient.new

    sweep(client, apply: true)

    assert_empty client.label_edits
  end

  # --- 8. the dormant-audit trap (Autodev #74, #81) -------------------------

  # A pass that writes an activity row on a line it declines keeps
  # `Issue.without_activity_since` non-empty forever, and the dormant audit plus
  # the "Issues bloquées" card can never select it again.
  def test_a_declined_row_writes_no_activity_event
    issue = arrear
    client = StubClient.new(mr: FakeMr.new('merged', 'mergeable', false))

    sweep(client, apply: true)

    assert_equal 0, ActivityEvent.where(issue_id: issue.id).count
  end

  def test_two_consecutive_runs_over_a_declined_population_write_nothing
    arrear
    client = StubClient.new(mr: FakeMr.new('locked', nil, nil))

    2.times { sweep(client, apply: true) }

    assert_equal 0, ActivityEvent.count
  end

  # Exactly one of each, and both are the audit trail: the AASM `transition` row
  # and the activity entry `reenter_via_pipeline_check` already posts.
  def test_a_rearmed_row_writes_exactly_one_row_of_each_kind
    issue = arrear

    sweep(StubClient.new, apply: true)

    assert_equal({ 'transition' => 1, 'danger_claude' => 1 },
                 ActivityEvent.where(issue_id: issue.id).group(:kind).count)
  end

  # --- 9. re-armed once, then given up again --------------------------------

  # Without a marker the row comes back with `review_count` still at 0 and the
  # sweep re-arms it every other run, forever. What the marker has to answer is
  # "did THIS sweep re-arm this row", and the run below is the only thing that
  # can put it there.
  def test_a_request_this_sweep_already_rearmed_is_not_rearmed_again
    issue = arrear
    client = StubClient.new
    sweep(client, apply: true)
    abandon_again(issue)
    @out = StringIO.new

    tally = sweep(client, apply: true)

    assert_equal 'done', issue.reload.status
    assert_equal 1, tally[:already_swept]
  end

  # The production shape, measured on the 01/09/2026 copy: 7 of the 23 rows
  # already carry a `reenter_to_check_pipeline` transition, all of them dated
  # June or July 2026 — BEFORE the August `finished_at` this sweep exists to
  # correct. That event has three writers (a human reposing the todo label,
  # `PollRouter#resume_recovered_infra`, and this sweep), and before Autodev #85
  # the infra one wrote `review_count: 1`, which is what used to keep those rows
  # out of the population. Reading the bare event name as "this sweep has re-armed
  # it" discards 30% of the arrears, silently and for ever.
  def test_a_reentry_this_sweep_did_not_write_is_not_its_marker
    issue = arrear
    reentry_event(issue, at: Time.parse('2026-07-06T13:58:07Z'))

    tally = sweep(StubClient.new, apply: true)

    assert_equal 'checking_pipeline', issue.reload.status
    assert_equal [0, 1], [tally[:already_swept], tally[:rearmed]]
  end

  # Same fact from the other side: the marker is written by the transition
  # itself, so it names its origin rather than its destination.
  def test_the_rearm_records_its_origin_on_the_transition_row
    issue = arrear

    sweep(StubClient.new, apply: true)

    payloads = ActivityEvent.where(issue_id: issue.id, kind: 'transition').map(&:payload)

    assert_equal([PollRouter::REVIEW_ARREARS_ORIGIN], payloads.map { |p| p['origin'] })
  end

  # A human reposing the todo label must not leave the sweep's marker behind.
  def test_a_human_reentry_records_no_origin
    issue = arrear(status: 'done', needs_attention: false, attention_reason: nil)
    router = PollRouter.new(config: CONFIG, project_config: PROJECT, logger: StubLogger.new,
                            token: 'x', pool: nil)
    GitlabHelpers.stub(:current_user_id, AUTODEV_USER_ID) do
      router.send(:resume_via_pipeline_check, issue, StubClient.new)
    end

    payload = ActivityEvent.where(issue_id: issue.id, kind: 'transition').first.payload

    refute payload.key?('origin'), "a reentry nobody attributed must carry no origin: #{payload.inspect}"
  end

  # --- 10. a re-arm that could not be finished ------------------------------

  # The chain the sweep used to walk into: `rearm` transitions the row, and only
  # then does `reenter_via_pipeline_check` call `apply_label_doing`, whose
  # `manage_labels` answers a GitLab error with a log line and `[]`. A transient
  # 500 therefore left `checking_pipeline` + `needs_attention: false` in the
  # database and the end label untouched on GitLab — and `dispatch_unassignment`,
  # which runs before `dispatch_pipelines`, reads that as a handover, closes the
  # row and posts a comment blaming a human for a move nobody made.
  def test_a_label_write_that_fails_stops_the_rearm
    issue = arrear
    client = failing_label_client(issue)

    tally = sweep(client, apply: true)

    assert_equal 'done', issue.reload.status
    assert_equal 1, tally[:incomplete]
    assert_empty client.assignee_edits
  end

  def test_a_label_write_that_fails_leaves_no_transition_behind
    issue = arrear

    sweep(failing_label_client(issue), apply: true)

    assert_equal 0, ActivityEvent.where(issue_id: issue.id).count
  end

  # The end of the same chain, asked of the ticket the sweep actually leaves on
  # GitLab: `LabelHandover#verdict` is the one definition of "somebody moved this
  # on", and a successfully re-armed ticket must not answer it.
  def test_a_rearmed_ticket_carries_no_handover_verdict
    issue = arrear
    client = StubClient.new(gl_issue: FakeGlIssue.new('opened', [FakeAssignee.new(AUTODEV_USER_ID)], [MOVED_ON]),
                            label_events: [moved_on_by(OTHER_HUMAN_ID)])
    sweep(client, apply: true)

    GitlabHelpers.stub(:current_user_id, AUTODEV_USER_ID) do
      assert_nil handover_for(client).verdict(client.issue(PATH, issue.issue_iid), issue.issue_iid)
    end
  end

  # `other_workflow_labels` is `labels_todo + label_doing + label_done +
  # label_attention` and knows nothing of `Development::Awaiting CR`, which five
  # production rows carry.
  #
  # This test used to assert that GitLab's own one-value-per-scope rule dropped it
  # from the `labels=` write that poses `Development::Doing` beside it — against a
  # stub that modelled the exclusivity. GitLab does not: it is a Premium feature,
  # source.modulotech.fr answers `enterprise: false`, and powerpanne/core#16224
  # carried both values at once on 02/09/2026. The test proved the false on the
  # exact mechanism the removal depended on (Autodev #98).
  #
  # What removes it is autodev, via `LabelHandover#scope_residue` — the same
  # definition of "in my scope but not mine" that detects a handover. So the
  # assertion is on the REQUEST as much as the result: the foreign value must not
  # be in the list autodev sends, because nothing downstream would take it out.
  def test_an_unconfigured_end_label_is_cleared_by_autodev_not_by_gitlab
    issue = arrear
    client = StubClient.new(gl_issue: FakeGlIssue.new('opened', [FakeAssignee.new(AUTODEV_USER_ID)], [MOVED_ON]))

    sweep(client, apply: true)

    assert_equal([[DOING]], client.label_edits.map { |_p, _i, opts| opts[:labels].split(',') })
    assert_equal [DOING], client.labels_of(issue.issue_iid)
  end

  # Two different natures, and the report has to tell them apart: nothing could
  # be established about the row (no slot spent, nothing written) versus the
  # re-arm started and stopped half-way (a slot spent, GitLab written to).
  def test_a_write_failure_is_not_reported_as_a_read_failure
    issue = arrear

    tally = sweep(failing_label_client(issue), apply: true)

    assert_equal 0, tally[:unreadable]
    refute_includes @out.string, 'could not be examined'
    assert_includes @out.string, 'incomplete'
  end

  # The mirror of `test_an_unreadable_row_does_not_consume_a_slot`: a row the
  # sweep started writing to did consume its slot, whatever the outcome.
  def test_a_rearm_that_started_and_failed_consumes_its_slot
    failing = arrear(issue_iid: 860, mr_iid: 900)
    eligible = arrear(issue_iid: 861, mr_iid: 901, finished_at: GIVEN_UP_AT + 3600)
    client = StubClient.new(gl_issues: { 860 => end_labelled_issue }, label_error_iids: [860])

    tally = sweep(client, apply: true, limit: 1)

    assert_equal [0, 1, 1], [tally[:rearmed], tally[:incomplete], tally[:deferred]]
    assert_equal %w[done done], [failing.reload.status, eligible.reload.status]
  end

  # `router_for` used to run AFTER `reclaim`, so a project missing from the
  # configuration reassigned the ticket to autodev and then raised.
  def test_a_row_whose_project_is_not_configured_writes_nothing
    issue = arrear(project_path: 'group/not-in-the-config')
    client = StubClient.new

    tally = sweep(client, apply: true)

    assert_equal [1, 0], [tally[:unreadable], tally[:rearmed]]
    assert_empty client.edits
    assert_equal 'done', issue.reload.status
  end

  # The only write left after the assignment is the local transition. If it goes,
  # the ticket must not stay assigned to autodev: nothing sweeps a `done` row, so
  # the human silently lost their assignment and — the part that matters — the
  # next default run would accept the row on `assigned_to_autodev?` alone, which
  # is exactly the widening `INCLUDE_AUTHOR_HANDBACK=1` is supposed to gate.
  def test_a_rearm_that_fails_after_the_assignment_hands_the_ticket_back
    issue = arrear
    client = handed_back_client

    tally = exploding_sweep(client, include_author_handback: true)

    assert_equal 'done', issue.reload.status
    assert_equal 1, tally[:incomplete]
    assert_equal [AUTHOR_ID], client.assignees_of(issue.issue_iid)
  end

  def test_a_rearm_that_failed_does_not_widen_the_default_population
    issue = arrear
    client = handed_back_client
    exploding_sweep(client, include_author_handback: true)
    @out = StringIO.new

    tally = sweep(client, apply: true)

    assert_equal [1, 0], [tally[:not_ours], tally[:rearmed]]
    assert_equal 'done', issue.reload.status
  end

  # --- 11. the assignee list is not autodev's to empty ----------------------

  # Autodev takes the ticket, because on GitLab Community it cannot join one
  # (Autodev #98). What makes that different from the silent removal the union
  # was introduced to stop is the next two tests: it is said, and it is recorded
  # so the ticket goes back to the right person.
  def test_reclaiming_takes_the_ticket_from_the_human
    issue = arrear
    client = handed_back_client

    sweep(client, apply: true, include_author_handback: true)

    assert_equal [[PATH, issue.issue_iid, { assignee_ids: [AUTODEV_USER_ID] }]], client.assignee_edits
    assert_equal [AUTODEV_USER_ID], client.assignees_of(issue.issue_iid)
  end

  # "With no comment and no trace anywhere autodev writes" is what made the old
  # substitution wrong. The taking is not.
  #
  # The reentry posts its own activity journal on the same ticket, so the notice
  # is looked for rather than counted — and it is looked for by the thing that
  # makes it a notice: it names the person whose ticket was taken. `@42` mentions
  # nobody on GitLab, which is why the address is a username.
  def test_a_takeover_is_announced_on_the_ticket
    arrear
    client = handed_back_client

    sweep(client, apply: true, include_author_handback: true)

    notice = client.created_notes.map(&:last).find { |body| body.include?('@the-author') }

    refute_nil notice, "no takeover notice among #{client.created_notes.size} note(s)"
  end

  # So the handback goes to whoever autodev took it from, and not to the ticket's
  # author — a different person on 4 of the 20 rows, and a deactivated account on
  # one of them.
  def test_a_takeover_records_who_it_displaced
    issue = arrear
    client = handed_back_client

    sweep(client, apply: true, include_author_handback: true)

    assert_equal AUTHOR_ID, issue.reload.displaced_assignee_id
  end

  # An unassigned ticket is in no tier, not even the widest: `dispatch_new_issues`
  # filters on assignment, so a ticket nobody holds is a ticket nobody is waiting
  # on, and this sweep's population is requests a human asked for.
  def test_an_unassigned_ticket_is_declined_by_every_tier
    issue = arrear
    client = StubClient.new(gl_issue: FakeGlIssue.new('opened', [], [DOING]))

    tally = sweep(client, apply: true, include_human_held: true)

    assert_equal 1, tally[:not_ours]
    assert_equal 'done', issue.reload.status
    assert_empty client.edits
  end

  # The `manage_labels` rule applied to the assignee list: a write that would
  # change nothing is not made.
  def test_a_ticket_already_assigned_to_autodev_is_not_reassigned
    arrear
    client = StubClient.new

    sweep(client, apply: true)

    assert_empty client.assignee_edits
  end

  # --- 12. LIMIT is an operator-typed number --------------------------------

  def test_an_absent_or_empty_limit_is_the_default
    assert_equal([3, 3, 3], [nil, '', '  '].map { |raw| Autodev::ReviewArrearsSweep.limit_from(raw) })
  end

  def test_a_limit_inside_the_range_is_read_in_base_ten
    assert_equal([5, 10], %w[5 010].map { |raw| Autodev::ReviewArrearsSweep.limit_from(raw) })
  end

  # `LIMIT=30`, one keystroke away from 3, re-armed the whole arrears in one run
  # — the shape of the 11/08/2026 incident the default exists to prevent.
  def test_a_limit_above_the_ceiling_is_refused
    error = assert_raises(ConfigError) { Autodev::ReviewArrearsSweep.limit_from('30') }

    assert_includes error.message, 'LIMIT'
    assert_includes error.message, Autodev::ReviewArrearsSweep::LIMIT_SPEC.max.to_s
  end

  def test_a_limit_at_or_below_zero_is_refused
    %w[0 -1].each do |raw|
      assert_raises(ConfigError, "LIMIT=#{raw} must be refused") { Autodev::ReviewArrearsSweep.limit_from(raw) }
    end
  end

  def test_a_limit_that_is_not_an_integer_is_refused
    %w[abc 3.7].each do |raw|
      assert_raises(ConfigError, "LIMIT=#{raw} must be refused") { Autodev::ReviewArrearsSweep.limit_from(raw) }
    end
  end

  def test_the_report_tells_a_never_swept_request_from_a_re_abandoned_one
    never = arrear(issue_iid: 850)
    again = arrear(issue_iid: 851)
    sweep_marker_event(again)

    sweep(StubClient.new)

    assert_match(/##{never.issue_iid} .*never re-armed/, @out.string)
    assert_match(/##{again.issue_iid} .*already re-armed by this sweep/, @out.string)
  end

  private

  # A router whose transition raises and whose every other method is the real
  # one: the local write is the last step of a re-arm, and this is what the row
  # and the ticket look like if it goes. Delegation rather than inheritance,
  # because `PollRouter.new` is what the test stubs and a subclass would inherit
  # the stub.
  class ExplodingRouter
    def initialize(real) = @real = real

    def repose_working_label(issue, client) = @real.repose_working_label(issue, client)

    def resume_never_reviewed(_issue, _client)
      raise ActiveRecord::StatementInvalid, 'database is locked'
    end
  end

  def end_labelled_issue = FakeGlIssue.new('opened', [FakeAssignee.new(AUTODEV_USER_ID)], [ATTENTION])

  def handed_back_client
    StubClient.new(gl_issue: FakeGlIssue.new('opened', [FakeAssignee.new(AUTHOR_ID, 'the-author')], [DOING]))
  end

  def failing_label_client(issue)
    StubClient.new(gl_issue: end_labelled_issue, label_error_iids: [issue.issue_iid])
  end

  def exploding_sweep(client, **)
    real = PollRouter.new(config: CONFIG, project_config: PROJECT, logger: StubLogger.new,
                          token: 'x', pool: nil)
    PollRouter.stub(:new, ExplodingRouter.new(real)) do
      sweep(client, apply: true, **)
    end
  end

  def handover_for(client)
    Autodev::LabelHandover.new(client: client, path: PATH, project_config: PROJECT, logger: StubLogger.new)
  end

  def moved_on_by(user_id)
    FakeLabelEvent.new('add', FakeLabel.new(MOVED_ON), '2026-07-01T10:00:00Z', FakeUser.new(user_id))
  end

  # A `reenter_to_check_pipeline` transition with no origin — a human reposing
  # the todo label, or the infra recheck.
  def reentry_event(issue, at: Time.current)
    ActivityEvent.create!(issue_id: issue.id, kind: 'transition', level: 'info', created_at: at,
                          payload_json: JSON.generate(from: 'done', to: 'checking_pipeline',
                                                      event: 'reenter_to_check_pipeline'))
  end

  # The same transition, written by this sweep.
  def sweep_marker_event(issue)
    ActivityEvent.create!(issue_id: issue.id, kind: 'transition', level: 'info',
                          payload_json: JSON.generate(from: 'done', to: 'checking_pipeline',
                                                      event: 'reenter_to_check_pipeline',
                                                      origin: PollRouter::REVIEW_ARREARS_ORIGIN))
  end

  # What `Reviewer#give_up_reviewing` does to a row it abandons a second time,
  # `update_all` so the AASM trail stays exactly what the first run left.
  def abandon_again(issue)
    Issue.where(id: issue.id).update_all(status: 'done', needs_attention: true,
                                         attention_reason: 'review_failures_exhausted',
                                         review_count: 0, review_failure_count: 5,
                                         finished_at: Time.current)
  end
end

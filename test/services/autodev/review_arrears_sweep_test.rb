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
  FakeAssignee = Struct.new(:id)
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
  class StubClient
    attr_reader :edits, :created_notes

    def initialize(**opts)
      @opts = opts
      @edits = []
      @created_notes = []
    end

    def issue(_path, iid)
      raise Gitlab::Error::ResponseError, response if Array(@opts[:issue_error_iids]).include?(iid)

      (@opts[:gl_issues] || {})[iid] || @opts[:gl_issue] || ReviewArrearsSweepTest.default_gl_issue
    end

    def merge_request(_path, iid)
      raise Gitlab::Error::ResponseError, response if Array(@opts[:mr_error_iids]).include?(iid)

      (@opts[:mrs] || {})[iid] || @opts[:mr] || ReviewArrearsSweepTest.open_mr
    end

    def issue_notes(_path, _iid, **_opts) = Paginated.new(Array(@opts[:notes]))
    def issue_label_events(_path, _iid) = Array(@opts[:label_events])
    def edit_issue(path, iid, **opts) = @edits << [path, iid, opts]
    def edit_issue_note(_path, _iid, _note_id, _body) = nil

    def create_issue_note(path, iid, _body)
      @created_notes << [path, iid]
      Struct.new(:id).new(1)
    end

    def label_edits = @edits.select { |_path, _iid, opts| opts.key?(:labels) }
    def assignee_edits = @edits.select { |_path, _iid, opts| opts.key?(:assignee_ids) }

    private

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

  def sweep(client, apply: false, limit: 3, include_author_handback: false)
    GitlabHelpers.stub(:build_gitlab_client, client) do
      GitlabHelpers.stub(:current_user_id, AUTODEV_USER_ID) do
        Autodev::ReviewArrearsSweep.new(config: CONFIG, apply: apply, limit: limit,
                                        include_author_handback: include_author_handback,
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

  # The MR facts travel to the operator, and none of them is a filter: a review
  # reads a diff, it does not need a mergeable MR, and a conflict is exactly what
  # a human has to be told about.
  def test_the_report_carries_the_merge_request_facts
    arrear
    sweep(StubClient.new(mr: FakeMr.new('opened', 'conflict', true)))

    assert_includes @out.string, 'state opened, merge status conflict, conflicts yes'
  end

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
  # unassignment is autodev's OWN write (`abandon_issue` → `reassign_to_author`),
  # so the strict rule declines 22 of the 23 rows it was meant to rescue.
  def test_a_ticket_handed_back_to_its_author_is_eligible_behind_the_flag
    issue = arrear
    client = StubClient.new(gl_issue: FakeGlIssue.new('opened', [FakeAssignee.new(AUTHOR_ID)], [DOING]))

    sweep(client, apply: true, include_author_handback: true)

    assert_equal 'checking_pipeline', issue.reload.status
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
  # GitLab comment on a human's ticket.
  def test_a_rearmed_request_is_reassigned_to_autodev
    issue = arrear
    client = StubClient.new(gl_issue: FakeGlIssue.new('opened', [FakeAssignee.new(AUTHOR_ID)], [DOING]))

    sweep(client, apply: true, include_author_handback: true)

    assert_equal [[PATH, issue.issue_iid, { assignee_ids: [AUTODEV_USER_ID] }]], client.assignee_edits
  end

  # `apply_label_doing` is load-bearing, not decorative: it strips the end labels,
  # and without it `stop_on_handover` reads a `workflow_moved` and closes the row.
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

  # Without this marker the row comes back with `review_count` still at 0 and the
  # sweep re-arms it every other run, forever.
  def test_a_request_already_rearmed_once_is_not_rearmed_again
    issue = arrear
    reentry_event(issue)

    tally = sweep(StubClient.new, apply: true)

    assert_equal 'done', issue.reload.status
    assert_equal 1, tally[:already_swept]
  end

  def test_the_report_tells_a_never_swept_request_from_a_re_abandoned_one
    never = arrear(issue_iid: 850)
    again = arrear(issue_iid: 851)
    reentry_event(again)

    sweep(StubClient.new)

    assert_match(/##{never.issue_iid} .*never re-armed/, @out.string)
    assert_match(/##{again.issue_iid} .*re-armed once already/, @out.string)
  end

  private

  def reentry_event(issue)
    ActivityEvent.create!(issue_id: issue.id, kind: 'transition', level: 'info',
                          payload_json: JSON.generate(from: 'done', to: 'checking_pipeline',
                                                      event: 'reenter_to_check_pipeline'))
  end
end

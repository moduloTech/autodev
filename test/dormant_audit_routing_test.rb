# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/activity_logger'

# What the dormant audit does with GitLab's answer (Autodev #47 + #48).
#
# One read, three outcomes. Closure wins over unassignment (a closed ticket is
# closed whether or not it is still assigned), and both win over re-arming —
# which is the whole point of #48 landing with #47 rather than after it: the two
# real cases found on 2026-08-06 were a ticket closed on GitLab (#16207) and one
# handed back to a human (#15909), both still sitting in `pending`. Re-arming
# either would have restarted work that is no longer ours.
class DormantAuditRoutingTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  include DatabaseTestHelper

  PROJECT_CONFIG = { 'path' => 'group/project', 'max_retries' => 1,
                     'labels_todo' => ['To Do'], 'label_doing' => 'Development::Doing',
                     'label_done' => 'Development::Awaiting Feature Review' }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example',
             'poll_interval' => 300 }.freeze
  AUTODEV_ID = 7
  HUMAN_ID = 999
  DOING = 'Development::Doing'
  AWAITING_CR = 'Development::Awaiting CR'

  FakeUser = Struct.new(:id)
  FakeAssignee = Struct.new(:id)
  FakeIssue = Struct.new(:state, :assignees, :labels)
  FakeLabel = Struct.new(:name)
  FakeEvent = Struct.new(:action, :label, :user)
  FakeNote = Struct.new(:id, :body)

  class StubClient
    attr_reader :calls, :notes

    def initialize(state: 'opened', assignee_ids: [AUTODEV_ID], labels: [DOING], events: [])
      @state = state
      @assignee_ids = assignee_ids
      @labels = labels
      @events = events
      @calls = 0
      @notes = []
    end

    def user = FakeUser.new(AUTODEV_ID)

    def issue(_project, _iid)
      @calls += 1
      FakeIssue.new(@state, @assignee_ids.map { |id| FakeAssignee.new(id) }, @labels)
    end

    def issue_label_events(_project, _iid) = @events

    def create_issue_note(_project, _iid, body)
      @notes << body
      FakeNote.new(@notes.size, body)
    end
  end

  def setup
    setup_database
    @logger = StubLogger.new
    GitlabHelpers.instance_variable_set(:@current_user_id, AUTODEV_ID)
  end

  def run_audit(issue, client: StubClient.new, config: CONFIG)
    Autodev::DormantAudit.new(client: client, path: PROJECT_CONFIG['path'], config: config,
                              project_config: PROJECT_CONFIG, logger: @logger).run
    issue.reload
  end

  def orphan(overrides = {})
    create_issue({ status: 'pending', next_retry_at: nil, created_at: 2.hours.ago }.merge(overrides))
  end

  def spent(overrides = {})
    create_issue({ status: 'error', retry_count: 2, created_at: 2.hours.ago }.merge(overrides))
  end

  # The shape `handle_auth_failure` (and the two generic handlers) leaves an
  # `error` row in since Autodev #103: budget unspent, no retry scheduled.
  def unstamped_within_budget(overrides = {})
    create_issue({ status: 'error', retry_count: 1, next_retry_at: nil,
                   created_at: 2.hours.ago }.merge(overrides))
  end

  # --- outcome 1: closed on GitLab (#16207) -------------------------

  def test_a_closed_pending_row_is_closed_locally
    issue = run_audit(orphan, client: StubClient.new(state: 'closed'))

    assert_equal 'closed', issue.status
  end

  def test_a_closed_error_row_is_closed_locally
    issue = run_audit(spent, client: StubClient.new(state: 'closed'))

    assert_equal 'closed', issue.status
  end

  def test_a_closed_row_is_not_rearmed
    issue = run_audit(spent, client: StubClient.new(state: 'closed'))

    assert_equal 2, issue.retry_count
  end

  # Closure wins: `closed` says more than `done`.
  def test_a_closed_and_unassigned_row_is_closed_not_done
    issue = run_audit(orphan, client: StubClient.new(state: 'closed', assignee_ids: [999]))

    assert_equal 'closed', issue.status
  end

  # --- outcome 2: handed back to a human (#15909) -------------------

  # `closed` since #52: a ticket a human took back was never delivered.
  def test_an_unassigned_pending_row_is_closed
    issue = run_audit(orphan, client: StubClient.new(assignee_ids: [HUMAN_ID]))

    assert_equal 'closed', issue.status
  end

  def test_an_unassigned_row_is_not_rearmed
    issue = run_audit(spent, client: StubClient.new(assignee_ids: [HUMAN_ID]))

    assert_equal 2, issue.retry_count
  end

  # --- outcome 2b: handed over via the labels (#52) -----------------
  #
  # A dormant row whose workflow label a human already moved on must not be
  # re-armed: the audit would restart work that is no longer ours. Same #48
  # ordering as the closure and the unassignment, applied to the third question.

  def handover_client
    StubClient.new(labels: [AWAITING_CR],
                   events: [FakeEvent.new('add', FakeLabel.new(AWAITING_CR), FakeUser.new(HUMAN_ID))])
  end

  def test_a_row_moved_to_another_workflow_label_is_closed
    issue = run_audit(orphan, client: handover_client)

    assert_equal 'closed', issue.status
  end

  def test_a_row_moved_to_another_workflow_label_is_not_rearmed
    issue = run_audit(orphan, client: handover_client)

    assert_nil issue.next_retry_at
  end

  # --- outcome 3: still ours -----------------------------------------

  def test_an_orphaned_pending_row_gets_a_due_stamp
    issue = run_audit(orphan)

    assert_equal 'pending', issue.status
    refute_nil issue.next_retry_at
    assert_operator issue.next_retry_at, :<=, Time.current
  end

  def test_a_spent_error_row_gets_its_budget_back
    issue = run_audit(spent)

    assert_equal 0, issue.retry_count
    refute_nil issue.next_retry_at
  end

  # A pruned worker left it mid-implementation; revive_stalled! owns the rules.
  def test_a_frozen_pre_mr_active_row_restarts_as_pending
    issue = run_audit(create_issue(status: 'implementing', mr_iid: nil, created_at: 4.hours.ago))

    assert_equal 'pending', issue.status
    refute_nil issue.next_retry_at
  end

  def test_a_frozen_post_mr_active_row_resumes_at_checking_pipeline
    issue = run_audit(create_issue(status: 'implementing', mr_iid: 42, created_at: 4.hours.ago))

    assert_equal 'checking_pipeline', issue.status
  end

  # --- outcome 3b: the parked-401 shape (Autodev #103) ----------------

  def test_an_unstamped_error_row_within_budget_gets_its_budget_reaffirmed
    issue = run_audit(unstamped_within_budget)

    assert_equal 0, issue.retry_count
    refute_nil issue.next_retry_at
  end

  def test_an_unstamped_error_row_within_budget_reaches_dormant_exhausted_at_the_cap
    issue = run_audit(unstamped_within_budget(dormant_recheck_count: CAP))

    assert issue.needs_attention
    assert_equal 'dormant_exhausted', issue.attention_reason
  end

  # --- the bound ------------------------------------------------------

  def test_auditing_costs_one_attempt_and_backs_off
    issue = run_audit(orphan)

    assert_equal 1, issue.dormant_recheck_count
    assert_operator issue.dormant_recheck_at, :>, Time.current
  end

  # Declining costs an attempt too, or a forgotten ticket makes us call GitLab
  # on every single poll forever.
  def test_declining_still_costs_an_attempt
    issue = run_audit(spent, client: StubClient.new(state: 'closed'))

    assert_equal 1, issue.dormant_recheck_count
  end

  def test_one_gitlab_read_per_candidate
    client = StubClient.new
    orphan
    Autodev::DormantAudit.new(client: client, path: PROJECT_CONFIG['path'], config: CONFIG,
                              project_config: PROJECT_CONFIG, logger: @logger).run

    assert_equal 1, client.calls
  end

  # --- resilience -----------------------------------------------------

  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  class FailingClient < StubClient
    def issue(_project, _iid)
      raise Gitlab::Error::ResponseError,
            FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/issues'))
    end
  end

  def test_a_gitlab_error_leaves_the_status_untouched
    issue = run_audit(orphan, client: FailingClient.new)

    assert_equal 'pending', issue.status
  end

  # The counter is bumped before the read on purpose: an unreachable project
  # burns the cap instead of being retried on every cycle forever.
  def test_a_gitlab_error_still_costs_an_attempt
    issue = run_audit(orphan, client: FailingClient.new)

    assert_equal 1, issue.dormant_recheck_count
  end

  # --- a failed handover read (Autodev #115) ---------------------------
  #
  # `route_still_assigned` reaches `LabelHandover#verdict`'s stage-2 read only
  # once stage 1 already found a candidate off the labels — this reuses
  # `handover_client`'s own suspicious-label shape (`AWAITING_CR`) and fails
  # the read that used to confirm or deny it. `verdict` used to answer this with
  # nil ("no handover") instead of aborting; `#audit`'s rescue is what has to
  # decline the row instead, per row, the same way it already did for the
  # `client.issue` read above.
  class HandoverReadFailingClient < StubClient
    def initialize
      super(labels: [AWAITING_CR])
    end

    def issue_label_events(_project, _iid)
      raise Gitlab::Error::ResponseError,
            FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/issues'))
    end
  end

  # Not "untouched": `audit` writes the recheck count and backoff stamp
  # *before* the read (see `test_a_failed_handover_read_still_costs_the_one_
  # recheck_attempt` below), on purpose — an unreachable project must burn the
  # cap rather than be retried forever. What this pins is narrower and is the
  # thing the bug was about: the row is not closed, and it is not re-armed
  # either (`retry_count`/`next_retry_at` from `revive` are untouched), so it
  # stays exactly `pending` for the next cycle to re-ask.
  def test_a_failed_handover_read_leaves_the_status_pending
    issue = run_audit(orphan, client: HandoverReadFailingClient.new)

    assert_equal 'pending', issue.status
  end

  def test_a_failed_handover_read_still_costs_the_one_recheck_attempt
    issue = run_audit(orphan, client: HandoverReadFailingClient.new)

    assert_equal 1, issue.dormant_recheck_count
  end

  # --- end of cap -----------------------------------------------------

  # #34's pass went silent when its cap ran out: the row became permanently
  # immobile with no signal anywhere. That is #47's own complaint — "real,
  # requested work, never done, with no signal" — so the pass replacing it must
  # not inherit it.
  #
  # The moment to signal is NOT a refused attempt: every routing outcome
  # resolves the row (closed, done, or given a path). A row dies quietly the
  # other way — it gets revived, falls dormant again, and after `cap` rounds it
  # simply stops being selected. So the condition is "at cap AND still dormant",
  # which needs no GitLab read at all.
  CAP = Autodev::PollDispatcher::DEFAULT_DORMANT_AUDIT_MAX

  def test_a_row_at_the_cap_and_still_dormant_is_flagged
    issue = run_audit(spent(dormant_recheck_count: CAP))

    assert issue.needs_attention
    assert_equal 'dormant_exhausted', issue.attention_reason
  end

  # `attention_detail` renders verbatim on the web card ("Job(s) en cause :
  # %{detail}"), so it must never hold a full sentence — there is no failing
  # job to name for this reason. Pinned nil so a future edit doesn't
  # reintroduce an untranslated sentence there (review round 1/5, Autodev #47).
  def test_exhaustion_does_not_set_attention_detail
    issue = run_audit(spent(dormant_recheck_count: CAP))

    assert_nil issue.attention_detail
  end

  def test_an_orphaned_pending_row_at_the_cap_is_flagged
    issue = run_audit(orphan(dormant_recheck_count: CAP))

    assert issue.needs_attention
  end

  def test_a_row_under_the_cap_is_not_flagged
    issue = run_audit(spent(dormant_recheck_count: CAP - 1))

    refute issue.needs_attention
  end

  # It was just revived: it has a path forward and is no longer dormant, so it
  # never enters the exhausted set even at the cap.
  def test_a_revived_row_is_not_flagged
    issue = run_audit(spent(dormant_recheck_count: CAP - 1))

    assert_equal 0, issue.retry_count
    refute issue.needs_attention
  end

  # Flagging must not rewrite the same signal on every single cycle: a first
  # cycle flags a fresh row at the cap (one warn event); a second cycle, run
  # against the now-flagged row, must not add a second one.
  #
  # NOTE: the brief's original version of this test pre-set needs_attention on
  # the fixture and asserted count == 1 after a *single* run_audit call. That
  # assertion holds with no ActivityEvent existing beforehand only if exhaust!
  # fires on an already-flagged row — i.e. it passes precisely when the
  # `.reject(&:needs_attention)` guard is *absent*, and fails when the guard is
  # present (confirmed experimentally: removing the guard made all 22 tests in
  # this file pass, including this one). That is backwards from "flag once,
  # not every cycle." Rewritten here to run two cycles so the assertion
  # actually exercises the guard.
  def test_an_already_flagged_row_is_not_reflagged
    at_cap = spent(dormant_recheck_count: CAP)
    run_audit(at_cap)
    run_audit(at_cap)

    assert_equal 1, ActivityEvent.where(issue_id: at_cap.id, level: 'warn').count
  end

  # The row is past the cap: it is not a candidate, so it costs nothing.
  def test_flagging_costs_no_gitlab_read
    client = StubClient.new
    spent(dormant_recheck_count: CAP)
    Autodev::DormantAudit.new(client: client, path: PROJECT_CONFIG['path'], config: CONFIG,
                              project_config: PROJECT_CONFIG, logger: @logger).run

    assert_equal 0, client.calls
  end

  def test_exhaustion_writes_a_warn_activity_event
    issue = run_audit(spent(dormant_recheck_count: CAP))
    event = ActivityEvent.where(issue_id: issue.id, level: 'warn').last

    refute_nil event
    assert_includes event.payload_json, 'dormant_exhausted'
  end
end

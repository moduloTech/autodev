# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/activity_logger'

# Autodev #86 — a request parked in `needs_clarification` has an owner.
#
# Before this, the one reader of the state was `dispatch_new_issues`, which only
# sees tickets still assigned to autodev and still carrying a todo label, and
# only ever *resumes*. A ticket reassigned to a human, a spent budget and a
# question nobody answers for months all left the row waiting in silence — row 68
# of production sat 131 days that way.
#
# `ClarificationWatch` flags the row (`needs_attention`, the row keeps waiting),
# reads GitLab only for a row that left the list the cycle already fetched, and
# writes nothing on a cycle where nothing changed.
class AParkedRequestHasAnOwnerTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  include DatabaseTestHelper

  PATH = 'group/project'
  AUTODEV_ID = 7
  HUMAN_ID = 999
  TODO = 'To Do'
  PROJECT_CONFIG = { 'path' => PATH, 'max_retries' => 3, 'clarification_max_days' => 14,
                     'labels_todo' => [TODO], 'label_doing' => 'Development::Doing',
                     'label_done' => 'Development::Done' }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example' }.freeze
  NOW = Time.utc(2026, 9, 23, 12, 0, 0)

  FakeUser = Struct.new(:id)
  FakeIssue = Struct.new(:state, :assignees, :labels)
  FakeNote = Struct.new(:id)
  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  # `issue` answers from a per-iid table; an iid it does not know is a test bug,
  # so it raises rather than inventing a ticket. `on_read` lets a test act on
  # the database in the middle of the read, the way a worker would.
  class StubClient
    attr_reader :reads, :notes

    def initialize(tickets = {}, on_read: nil, raises: {})
      @tickets = tickets
      @on_read = on_read
      @raises = raises
      @reads = []
      @notes = []
    end

    def user = FakeUser.new(AUTODEV_ID)

    def issue(_path, iid)
      @reads << iid
      raise @raises[iid] if @raises.key?(iid)

      @on_read&.call(iid)
      @tickets.fetch(iid)
    end

    def create_issue_note(_path, _iid, body)
      @notes << body
      FakeNote.new(@notes.size)
    end

    def issue_note(*) = FakeNote.new(1)
    def edit_issue_note(*) = nil
  end

  def ticket(state: 'opened', assignee_ids: [AUTODEV_ID], labels: [TODO])
    FakeIssue.new(state, assignee_ids.map { |id| FakeUser.new(id) }, labels)
  end

  def parked(overrides = {})
    create_issue({ project_path: PATH, status: 'needs_clarification', retry_count: 0,
                   clarification_requested_at: NOW - 1.day }.merge(overrides))
  end

  def watch(client: StubClient.new, seen: [], project_config: PROJECT_CONFIG, config: CONFIG, listed_at: nil)
    Autodev::ClarificationWatch.new(client: client, path: PATH, config: config,
                                    project_config: project_config, logger: @logger,
                                    seen_iids: seen, listed_at: listed_at, now: NOW)
  end

  def warn_events(issue)
    ActivityEvent.where(issue_id: issue.id, level: 'warn').to_a
  end

  def issue_updates
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe('sql.active_record') do |*, payload|
      statements << payload[:sql] if payload[:sql].match?(/\AUPDATE "issues"/)
    end
    yield
    statements
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  def setup
    setup_database
    @logger = StubLogger.new
    GitlabHelpers.instance_variable_set(:@current_user_id, AUTODEV_ID)
  end

  # --- the reach arm: only a row absent from the fetched list is read ---------

  # The nominal case, and why the pass is cheap: a healthy parked row carries
  # its reposed entry label, so it is in the list the cycle already fetched.
  def test_a_row_in_the_seen_list_costs_no_read
    issue = parked
    client = StubClient.new

    watch(client: client, seen: [issue.issue_iid]).run

    assert_empty client.reads
    refute issue.reload.needs_attention
  end

  def test_an_absent_row_is_read_once
    issue = parked
    client = StubClient.new({ issue.issue_iid => ticket })

    watch(client: client).run

    assert_equal [issue.issue_iid], client.reads
  end

  def test_a_row_closed_on_gitlab_is_closed
    issue = parked
    watch(client: StubClient.new({ issue.issue_iid => ticket(state: 'closed') })).run

    assert_equal 'closed', issue.reload.status
  end

  # Flag and keep, never close: re-entry from `closed` needs a todo label posed
  # *after* `finished_at`, and a parked ticket already carries one, so closing
  # would make the documented "reassign me" gesture a silent no-op.
  def test_a_row_reassigned_to_a_human_is_flagged_and_keeps_waiting
    issue = parked
    watch(client: StubClient.new({ issue.issue_iid => ticket(assignee_ids: [HUMAN_ID]) })).run

    issue.reload

    assert_equal 'needs_clarification', issue.status
    assert issue.needs_attention
    assert_equal 'clarification_reassigned', issue.attention_reason
  end

  def test_a_row_whose_entry_label_is_gone_is_flagged_label_moved
    issue = parked
    watch(client: StubClient.new({ issue.issue_iid => ticket(labels: ['Development::Doing']) })).run

    assert_equal 'clarification_label_moved', issue.reload.attention_reason
  end

  # Parked after the list was fetched: nothing is wrong with it.
  def test_an_assigned_row_still_carrying_a_todo_label_is_left_alone
    issue = parked
    watch(client: StubClient.new({ issue.issue_iid => ticket })).run

    refute issue.reload.needs_attention
  end

  # Test 16: any value of `labels_todo` is the entry label, not only the first.
  def test_a_row_carrying_the_second_todo_label_is_not_flagged
    issue = parked
    config = PROJECT_CONFIG.merge('labels_todo' => %w[A B])
    watch(client: StubClient.new({ issue.issue_iid => ticket(labels: ['B']) }), project_config: config).run

    refute issue.reload.needs_attention
  end

  # Autodev #62: a read that did not answer is never a verdict.
  def test_a_failed_read_leaves_the_row_untouched
    issue = parked
    error = Gitlab::Error::ResponseError.new(
      FakeResponse.new('boom', 502, FakeRequest.new('https://gitlab.example', '/api/v4/issues'))
    )
    watch(client: StubClient.new({}, raises: { issue.issue_iid => error })).run

    issue.reload

    assert_equal 'needs_clarification', issue.status
    refute issue.needs_attention
  end

  # The Claude gate closed, so `dispatch_new_issues` fetched nothing: absence
  # from a list nobody asked for means nothing.
  def test_no_seen_list_means_no_read_at_all
    parked
    client = StubClient.new

    watch(client: client, seen: nil).run

    assert_empty client.reads
  end

  # A reach flag is re-read while the row stays out of the list (truthfulness
  # and adversarial reviews of #86). The first version did not re-read it, to
  # save 288 reads per row per day, and the flag then froze on whatever GitLab
  # said the first time: a ticket leaving in two steps kept the first step's
  # explanation, the gesture that explanation prescribes changed nothing on the
  # card, and a flagged ticket closed on GitLab never closed the row.
  def test_a_ticket_leaving_in_two_steps_is_described_by_the_second
    issue = parked(needs_attention: true, attention_reason: 'clarification_label_moved')
    client = StubClient.new({ issue.issue_iid => ticket(assignee_ids: [HUMAN_ID], labels: []) })

    watch(client: client).run

    assert_equal [issue.issue_iid], client.reads
    assert_equal 'clarification_reassigned', issue.reload.attention_reason
  end

  # The gesture `clarification_reassigned` prescribes, done without the entry
  # label: the fresh reading replaces the old one even though it ranks lower.
  def test_a_reassigned_row_given_back_without_its_label_becomes_label_moved
    issue = parked(needs_attention: true, attention_reason: 'clarification_reassigned')
    client = StubClient.new({ issue.issue_iid => ticket(labels: []) })

    watch(client: client).run

    assert_equal 'clarification_label_moved', issue.reload.attention_reason
  end

  def test_a_reach_flagged_row_whose_ticket_was_closed_is_closed
    issue = parked(needs_attention: true, attention_reason: 'clarification_reassigned')
    client = StubClient.new({ issue.issue_iid => ticket(state: 'closed', assignee_ids: [HUMAN_ID]) })

    watch(client: client).run

    assert_equal 'closed', issue.reload.status
  end

  # Read healthy while absent from the list: it parked after the list was
  # fetched, or GitLab's list lagged. Reachable is reachable.
  def test_a_reach_flagged_row_read_healthy_is_cleared
    issue = parked(needs_attention: true, attention_reason: 'clarification_reassigned')
    client = StubClient.new({ issue.issue_iid => ticket })

    watch(client: client).run

    refute issue.reload.needs_attention
  end

  # Still reassigned: re-read, and nothing written — the pass stays quiet on a
  # cycle where nothing changed.
  def test_a_still_reassigned_row_is_read_and_left_as_it_is
    issue = parked(needs_attention: true, attention_reason: 'clarification_reassigned')
    client = StubClient.new({ issue.issue_iid => ticket(assignee_ids: [HUMAN_ID]) })

    updates = issue_updates { watch(client: client).run }

    assert_equal [issue.issue_iid], client.reads
    assert_empty updates
    assert_empty warn_events(issue)
  end

  # The race the adversarial review confirmed: `post_clarification` parks the
  # row (`spec_unclear!`, then the stamp) before it reposes the entry label. A
  # row parked after the list was fetched is absent from it for that reason
  # alone, and a read in that window sees `label_doing` — a false
  # `clarification_label_moved`, and an activity entry nothing prunes.
  def test_a_row_parked_after_the_list_was_fetched_is_not_read
    issue = parked(clarification_requested_at: NOW - 10.seconds)
    client = StubClient.new({ issue.issue_iid => ticket(labels: ['Development::Doing']) })

    watch(client: client, listed_at: NOW - 1.minute).run

    assert_empty client.reads
    refute issue.reload.needs_attention
  end

  # The same instant is "after": the stamp and the fetch are both taken before
  # anything they describe, so equality proves nothing either way.
  def test_a_row_stamped_at_the_very_instant_of_the_fetch_is_not_read
    issue = parked(clarification_requested_at: NOW - 1.minute)
    client = StubClient.new({ issue.issue_iid => ticket(labels: ['Development::Doing']) })

    watch(client: client, listed_at: NOW - 1.minute).run

    assert_empty client.reads
  end

  def test_a_row_parked_before_the_list_was_fetched_is_read
    issue = parked(clarification_requested_at: NOW - 2.minutes)
    client = StubClient.new({ issue.issue_iid => ticket(labels: ['Development::Doing']) })

    watch(client: client, listed_at: NOW - 1.minute).run

    assert_equal 'clarification_label_moved', issue.reload.attention_reason
  end

  def test_a_reach_flag_is_cleared_once_the_row_is_back_in_the_list
    issue = parked(needs_attention: true, attention_reason: 'clarification_label_moved')

    watch(seen: [issue.issue_iid]).run

    issue.reload

    refute issue.needs_attention
    assert_nil issue.attention_reason
  end

  # --- the database arms: budget and age --------------------------------------

  def run_on(issue, **)
    watch(seen: [issue.issue_iid], **).run
    issue.reload
  end

  # Test 6. `>`, like `exceeded_retries?`: a row at the budget still has one owed.
  def test_a_row_exactly_at_the_budget_is_not_flagged
    refute run_on(parked(retry_count: 3)).needs_attention
  end

  def test_a_row_over_the_budget_is_flagged
    assert_equal 'clarification_budget_spent', run_on(parked(retry_count: 4)).attention_reason
  end

  def test_the_global_budget_applies_when_the_project_sets_none
    project_config = PROJECT_CONFIG.except('max_retries')

    refute run_on(parked(retry_count: 2), project_config: project_config,
                                          config: CONFIG.merge('max_retries' => 3)).needs_attention
  end

  def test_a_question_older_than_the_bound_is_flagged_unanswered
    issue = run_on(parked(clarification_requested_at: NOW - 15.days))

    assert_equal 'clarification_unanswered', issue.attention_reason
    assert_equal 'needs_clarification', issue.status
  end

  # Same boundary as `WatchBound#abandon_expired_watch`: the bound is reached
  # on the day it names.
  def test_a_question_exactly_at_the_bound_is_flagged
    assert run_on(parked(clarification_requested_at: NOW - 14.days)).needs_attention
  end

  def test_a_question_just_under_the_bound_is_not_flagged
    refute run_on(parked(clarification_requested_at: NOW - 14.days + 1.second)).needs_attention
  end

  def test_zero_switches_the_age_bound_off
    project_config = PROJECT_CONFIG.merge('clarification_max_days' => 0)

    refute run_on(parked(clarification_requested_at: NOW - 400.days),
                  project_config: project_config).needs_attention
  end

  # No question on record reads as answered (`ClarificationResume#answered?`),
  # so there is nothing to age.
  def test_a_row_with_no_question_on_record_is_not_aged
    refute run_on(parked(clarification_requested_at: nil)).needs_attention
  end

  # Budget and age flags are cleared by a resume or a reset, never by the pass.
  def test_a_budget_flag_survives_a_row_back_in_the_list
    issue = run_on(parked(retry_count: 0, needs_attention: true,
                          attention_reason: 'clarification_budget_spent'))

    assert_equal 'clarification_budget_spent', issue.attention_reason
  end

  # --- one reason per row, ranked, and written only when it changes -----------

  def test_the_order_of_the_reasons_is_the_contract
    assert_equal %w[clarification_reassigned clarification_label_moved
                    clarification_budget_spent clarification_unanswered],
                 Autodev::ClarificationWatch::REASONS
  end

  # Test 8, first half.
  def test_budget_outranks_age_on_one_row
    issue = parked(retry_count: 4, clarification_requested_at: NOW - 30.days)
    watch(seen: [issue.issue_iid]).run

    assert_equal 'clarification_budget_spent', issue.reload.attention_reason
  end

  # Test 8, second half: the reach flag clears and the budget flag lands in the
  # same run, not one cycle later.
  def test_a_reach_flag_back_in_the_list_gives_way_to_a_spent_budget_in_one_run
    issue = parked(retry_count: 4, needs_attention: true, attention_reason: 'clarification_reassigned')
    watch(seen: [issue.issue_iid]).run

    assert_equal 'clarification_budget_spent', issue.reload.attention_reason
  end

  def test_a_weaker_flag_never_overwrites_a_stronger_one
    issue = parked(retry_count: 4, needs_attention: true, attention_reason: 'clarification_reassigned')
    watch(client: StubClient.new({ issue.issue_iid => ticket(assignee_ids: [HUMAN_ID]) })).run

    assert_equal 'clarification_reassigned', issue.reload.attention_reason
  end

  def test_a_stronger_flag_overwrites_a_weaker_one
    issue = parked(needs_attention: true, attention_reason: 'clarification_unanswered')
    watch(client: StubClient.new({ issue.issue_iid => ticket(assignee_ids: [HUMAN_ID]) })).run

    assert_equal 'clarification_reassigned', issue.reload.attention_reason
  end

  # Test 15. `dormant_exhausted` reaches this state through the CLI `--reset`,
  # which does not clear attention. It ranks below every clarification reason.
  def test_a_foreign_reason_is_overwritten_by_any_arm
    issue = parked(retry_count: 4, needs_attention: true, attention_reason: 'dormant_exhausted')
    watch(seen: [issue.issue_iid]).run

    assert_equal 'clarification_budget_spent', issue.reload.attention_reason
  end

  def test_the_reach_clear_never_touches_a_foreign_reason
    issue = parked(needs_attention: true, attention_reason: 'dormant_exhausted')
    watch(seen: [issue.issue_iid]).run

    assert_equal 'dormant_exhausted', issue.reload.attention_reason
  end

  # Test 9: the pass writes nothing on a cycle where nothing changed — neither
  # the row nor an activity entry, which would also feed `without_activity_since`.
  # One row per arm, the two database ones sitting in the seen list.
  def test_a_second_run_on_flagged_rows_writes_nothing
    client, seen = one_flagged_row_per_arm
    watch(client: client, seen: seen).run
    events_before = ActivityEvent.count

    updates = issue_updates { watch(client: client, seen: seen).run }

    assert_empty updates
    assert_equal events_before, ActivityEvent.count
  end

  def one_flagged_row_per_arm
    seen = [parked(retry_count: 4), parked(clarification_requested_at: NOW - 30.days)].map(&:issue_iid)
    [StubClient.new({ parked.issue_iid => ticket(assignee_ids: [HUMAN_ID]) }), seen]
  end

  # Test 10: flagged, unchanged-flagged, closed → 2.
  def test_run_counts_the_rows_it_changed_or_closed
    parked(retry_count: 4)
    unchanged = parked(retry_count: 4, needs_attention: true, attention_reason: 'clarification_budget_spent')
    closed = parked
    client = StubClient.new({ closed.issue_iid => ticket(state: 'closed') })
    seen = Issue.where.not(id: closed.id).pluck(:issue_iid)

    assert_equal 2, watch(client: client, seen: seen).run
    assert_equal 'clarification_budget_spent', unchanged.reload.attention_reason
  end

  def test_a_cleared_reach_flag_counts_as_a_change
    issue = parked(needs_attention: true, attention_reason: 'clarification_reassigned')

    assert_equal 1, watch(seen: [issue.issue_iid]).run
  end

  # --- the write: compare-and-set, one warn entry, per-row boundary -----------

  # Test 11: a worker resumed the row while GitLab was being read.
  def test_a_row_that_left_the_state_during_the_read_is_not_flagged
    issue = parked
    resume = ->(_iid) { Issue.where(id: issue.id).update_all(status: 'pending') }
    client = StubClient.new({ issue.issue_iid => ticket(assignee_ids: [HUMAN_ID]) }, on_read: resume)

    assert_equal 0, watch(client: client).run

    refute issue.reload.needs_attention
    assert_empty warn_events(issue)
  end

  # Test 12: a missing interpolation variable makes `warn_event` write nothing,
  # silently, so each reason's entry is asserted with its numbers.
  def test_the_reassigned_entry_is_written
    issue = parked(locale: 'en')
    watch(client: StubClient.new({ issue.issue_iid => ticket(assignee_ids: [HUMAN_ID]) })).run

    assert_includes warn_message(issue), 'no longer assigned'
  end

  def test_the_label_moved_entry_is_written
    issue = parked(locale: 'en')
    watch(client: StubClient.new({ issue.issue_iid => ticket(labels: []) })).run

    assert_includes warn_message(issue), 'entry label'
  end

  def test_the_budget_entry_carries_the_count_and_the_budget
    issue = parked(retry_count: 4, locale: 'en')
    watch(seen: [issue.issue_iid]).run

    assert_includes warn_message(issue), '(4/3)'
  end

  def test_the_age_entry_carries_the_bound
    issue = parked(clarification_requested_at: NOW - 30.days, locale: 'en')
    watch(seen: [issue.issue_iid]).run

    assert_includes warn_message(issue), '14 days'
  end

  # The one warn entry of the row, past the timestamp prefix whose digits would
  # satisfy any number. A count instead when there is not exactly one, so the
  # failing assertion says what was written.
  def warn_message(issue)
    events = warn_events(issue)
    return "#{events.size} warn entries" unless events.size == 1

    JSON.parse(events.first.payload_json)['message'].split(' — ', 2).last
  end

  # Test 14: the row moved between the select and the closure.
  def test_a_closure_refused_as_stale_does_not_stop_the_next_row
    stale = parked
    later = parked
    watch(client: closed_then_moved(stale, later)).run

    assert_equal 'pending', stale.reload.status
    assert_equal 'clarification_reassigned', later.reload.attention_reason
  end

  # `stale` is closed on GitLab and resumed in the database during the read;
  # `later` was reassigned.
  def closed_then_moved(stale, later)
    move = ->(iid) { Issue.where(id: stale.id).update_all(status: 'pending') if iid == stale.issue_iid }
    StubClient.new({ stale.issue_iid => ticket(state: 'closed'),
                     later.issue_iid => ticket(assignee_ids: [HUMAN_ID]) }, on_read: move)
  end

  def test_a_transport_error_on_one_row_does_not_stop_the_next
    broken = parked
    later = parked
    client = StubClient.new({ later.issue_iid => ticket(assignee_ids: [HUMAN_ID]) },
                            raises: { broken.issue_iid => Net::ReadTimeout.new })

    watch(client: client).run

    refute broken.reload.needs_attention
    assert_equal 'clarification_reassigned', later.reload.attention_reason
  end

  # Operator signal only, like `dormant_exhausted`: no GitLab comment.
  def test_a_flag_posts_nothing_on_gitlab
    issue = parked
    client = StubClient.new({ issue.issue_iid => ticket(assignee_ids: [HUMAN_ID]) })
    watch(client: client).run

    assert_empty client.notes
  end
end

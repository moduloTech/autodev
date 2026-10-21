# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/activity_logger'
require 'active_support/testing/time_helpers'
require 'autodev/mr_fixer'

# A row that completes a unit of work gets its dormant budget back, and loses a
# `dormant_exhausted` flag (Autodev #129, #135).
#
# #129: `dormant_recheck_count` was spent over the whole life of a row, so four
# unrelated incidents weeks apart, each resolved, flagged the fourth instead of
# reviving it. #135: a row flagged `dormant_exhausted` that restarted on its own
# kept the flag, and the dashboard showed as given up a request that was pushing
# corrections.
#
# The other half of the contract is the bound: the revival itself never counts,
# and neither does re-reading a pipeline that was already green — a step that
# keeps dying is still given up after `dormant_audit_max` revivals.
class ProgressReturnsTheDormantBudgetTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  include DatabaseTestHelper
  include ActiveSupport::Testing::TimeHelpers

  PROJECT_CONFIG = { 'path' => 'group/project', 'max_retries' => 1,
                     'labels_todo' => ['To Do'], 'label_doing' => 'Development::Doing',
                     'label_done' => 'Development::Awaiting Feature Review' }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example',
             'poll_interval' => 300 }.freeze
  AUTODEV_ID = 7
  DOING = 'Development::Doing'
  STAMP = Time.utc(2030, 1, 1)
  EXHAUSTED = { dormant_recheck_count: 3, needs_attention: true,
                attention_reason: 'dormant_exhausted' }.freeze

  # What counts, as `[event, destination]`; `nil` is any destination.
  COUNTED = [[:mr_created, nil], [:discussions_fixed, nil], [:pipeline_fix_done, nil],
             %i[pipeline_green done], %i[mr_closed done], %i[question_answered done]].freeze

  # Every other event, with the reason it is not progress. Derived against
  # `Issue.aasm.events`: a new event fails `test_every_event_is_classified` until
  # somebody writes down which side it is on.
  NOT_COUNTED = {
    start_processing: 'entering a step', spec_clear: 'entering a step',
    spec_unclear: 'a wait', question_detected: 'entering a step',
    clone_complete: 'entering a step, or a closed ticket — not a delivery',
    impl_complete: 'an intermediate step', commit_complete: 'an intermediate step',
    push_complete: 'an intermediate step',
    pipeline_green: 'to reviewing / fixing_discussions it re-reads a pipeline a revival lands on',
    post_completion_done: 'the delivery already counted', start_post_completion: 'after the delivery',
    review_done: 'also fired by resume_watch on a review that did nothing',
    review_giveup: 'a give-up', pipeline_failed_code: 'entering a step', abandon: 'a give-up',
    functional_question: 'a wait', mr_ended_while_waiting: 'nothing was completed',
    clarification_received: 'an answer, not a completion',
    reenter: 'a re-entry, handled by its caller (#125)',
    reenter_to_check_pipeline: 'a re-entry, handled by its caller (#125)',
    mark_failed: 'a failure', retry_processing: 'the revival itself',
    retry_pipeline: 'the revival itself', close: 'a stop'
  }.freeze

  FakeUser = Struct.new(:id)
  FakeAssignee = Struct.new(:id)
  FakeIssue = Struct.new(:state, :assignees, :labels)

  # Open, assigned to autodev, on the working label: the audit's three
  # questions all answer "still ours", so every audit revives.
  class StubClient
    def user = FakeUser.new(AUTODEV_ID)
    def issue(_project, _iid) = FakeIssue.new('opened', [FakeAssignee.new(AUTODEV_ID)], [DOING])
    def issue_label_events(_project, _iid) = Gitlab::PaginatedResponse.new([])
  end

  def setup
    setup_database
    @logger = StubLogger.new
    GitlabHelpers.instance_variable_set(:@current_user_id, AUTODEV_ID)
  end

  def teardown
    travel_back
  end

  # --- the classification ------------------------------------------------

  def test_every_event_is_classified
    unclassified = Issue.aasm.events.map(&:name) - NOT_COUNTED.keys - COUNTED.map(&:first)

    assert_empty unclassified, 'classify each new AASM event in COUNTED or NOT_COUNTED'
  end

  def test_a_counted_transition_returns_the_budget
    counted_transitions.each do |event, transition|
      issue = fire(event, transition, EXHAUSTED.merge(dormant_recheck_at: 1.day.from_now))

      assert_equal [0, nil], [issue.dormant_recheck_count, issue.dormant_recheck_at],
                   "#{event} → #{transition.to} should return the budget"
    end
  end

  def test_a_counted_transition_lifts_the_dormant_flag
    counted_transitions.each do |event, transition|
      issue = fire(event, transition, EXHAUSTED.merge(attention_detail: 'x'))

      assert_equal [false, nil, nil], [issue.needs_attention, issue.attention_reason, issue.attention_detail],
                   "#{event} → #{transition.to} should lift dormant_exhausted"
    end
  end

  # Every transition is taken, none refused: a skipped one would judge nothing.
  def test_no_other_transition_returns_the_budget_or_lifts_the_flag
    all_transitions.reject { |event, transition| counted?(event, transition.to) }
                   .each { |event, transition| assert_untouched(event, transition) }
  end

  # The two branches the owner's list would have counted and the bound cannot.
  def test_a_green_pipeline_leading_into_a_step_is_not_progress
    %i[reviewing fixing_discussions].each do |to|
      transition = Issue.aasm.events.find { |e| e.name == :pipeline_green }.transitions.find { |t| t.to == to }
      issue = fire(:pipeline_green, transition, EXHAUSTED)

      assert_equal [to.to_s, 3, 'dormant_exhausted'],
                   [issue.status, issue.dormant_recheck_count, issue.attention_reason]
    end
  end

  # --- what the flag reads -----------------------------------------------

  def test_another_attention_reason_survives_progress
    issue = create_issue(status: 'fixing_pipeline', mr_iid: 1, needs_attention: true,
                         attention_reason: 'review_failures_exhausted', dormant_recheck_count: 3)
    issue.pipeline_fix_done!
    issue.reload

    assert_equal [true, 'review_failures_exhausted', 0],
                 [issue.needs_attention, issue.attention_reason, issue.dormant_recheck_count]
  end

  # The worker loaded the row before the audit flagged it from another process.
  def test_a_flag_written_since_the_load_is_lifted
    issue = create_issue(status: 'fixing_pipeline', mr_iid: 1)
    Issue.where(id: issue.id).update_all(EXHAUSTED)
    issue.pipeline_fix_done!
    issue.reload

    assert_equal [false, nil, 0], [issue.needs_attention, issue.attention_reason, issue.dormant_recheck_count]
  end

  # The loaded object still says dormant_exhausted; the database says something
  # else now. The database wins: nothing is cleared that the row no longer holds.
  def test_a_flag_replaced_since_the_load_is_left_alone
    issue = create_issue(EXHAUSTED.merge(status: 'fixing_pipeline', mr_iid: 1))
    Issue.where(id: issue.id).update_all(attention_reason: 'review_failures_exhausted')
    issue.pipeline_fix_done!
    issue.reload

    assert_equal [true, 'review_failures_exhausted'], [issue.needs_attention, issue.attention_reason]
  end

  # The loaded object read 0, the audit has bumped it since: still reset.
  def test_a_count_bumped_since_the_load_is_reset
    issue = create_issue(status: 'fixing_pipeline', mr_iid: 1)
    Issue.where(id: issue.id).update_all(dormant_recheck_count: 2, dormant_recheck_at: 1.hour.from_now)
    issue.pipeline_fix_done!
    issue.reload

    assert_equal [0, nil], [issue.dormant_recheck_count, issue.dormant_recheck_at]
  end

  # Autodev #97: a transition refused as stale writes nothing — this included.
  def test_a_refused_transition_returns_nothing
    issue = create_issue(EXHAUSTED.merge(status: 'fixing_pipeline', mr_iid: 1))
    Issue.where(id: issue.id).update_all(status: 'closed')

    assert_raises(StaleTransitionError) { issue.pipeline_fix_done! }
    issue.reload

    assert_equal [3, 'dormant_exhausted'], [issue.dormant_recheck_count, issue.attention_reason]
  end

  # The caller the classification cannot see from the model: a fix pass that
  # finds no thread left fires `discussions_fixed` without advancing a round
  # counter. It still counts — the step it was revived into is over, and the
  # next poll either delivers (no thread) or reads the same list `MrFixer` did,
  # so it cannot send the row back into an empty round — and the test pins that.
  def test_a_fix_pass_that_finds_nothing_left_is_progress
    issue = create_issue(EXHAUSTED.merge(status: 'fixing_discussions', mr_iid: 1, discussion_fix_round: 2))
    bare_fixer.fix(issue)
    issue.reload

    assert_equal ['checking_pipeline', 2, 0, nil],
                 [issue.status, issue.discussion_fix_round, issue.dormant_recheck_count, issue.attention_reason]
  end

  # --- #135: an automatic restart, then progress -------------------------

  def test_an_automatic_retry_alone_keeps_the_flag_and_the_count
    issue = create_issue(EXHAUSTED.merge(status: 'error', mr_iid: 1))
    issue.retry_pipeline!
    issue.reload

    assert_equal ['checking_pipeline', 3, 'dormant_exhausted'],
                 [issue.status, issue.dormant_recheck_count, issue.attention_reason]
  end

  def test_a_flagged_row_that_restarts_and_advances_is_no_longer_given_up
    issue = create_issue(EXHAUSTED.merge(status: 'error', mr_iid: 1))
    issue.retry_pipeline!
    issue.pipeline_failed_code!
    issue.pipeline_fix_done!
    issue.reload

    assert_equal [false, nil, 0], [issue.needs_attention, issue.attention_reason, issue.dormant_recheck_count]
  end

  # --- #129: the replay, and the bound -----------------------------------

  # #128's incident four times, ten days apart: a correction fails before
  # `pipeline_failed_code!`, the audit revives, the retry runs, and the next
  # correction goes through.
  def test_four_spaced_incidents_each_followed_by_progress_are_all_revived
    issue = create_issue(status: 'checking_pipeline', mr_iid: 1, created_at: 60.days.ago)
    4.times do |k|
      incident(issue, at: (40 - (10 * k)).days.ago)
      issue.pipeline_failed_code!
      issue.pipeline_fix_done!
    end

    assert_equal [false, 0], [issue.reload.needs_attention, issue.dormant_recheck_count]
  end

  def test_the_same_failure_relaunched_without_progress_still_exhausts
    issue = create_issue(status: 'checking_pipeline', mr_iid: 1, created_at: 60.days.ago)
    3.times { |k| incident(issue, at: (40 - (10 * k)).days.ago) }
    fail_and_audit(issue, at: 10.days.ago)

    assert_equal %w[error dormant_exhausted], [issue.reload.status, issue.attention_reason]
  end

  # A step that dies every time (a worker pruned in `fixing_discussions`): the
  # active arm revives it to `checking_pipeline`, whose next poll reads the same
  # green pipeline and sends it straight back. Counting that `pipeline_green`
  # would return the budget on every lap and the loop would never end.
  def test_a_step_that_keeps_dying_after_a_green_pipeline_still_exhausts
    issue = create_issue(status: 'fixing_discussions', mr_iid: 1, review_count: 1, created_at: 60.days.ago)
    4.times { |k| die_and_come_back_green(issue, at: (40 - (10 * k)).days.ago) }

    assert_equal %w[fixing_discussions dormant_exhausted], [issue.reload.status, issue.attention_reason]
  end

  private

  def all_transitions
    Issue.aasm.events.flat_map { |event| event.transitions.map { |t| [event.name, t] } }
  end

  def counted_transitions = all_transitions.select { |event, transition| counted?(event, transition.to) }

  def counted?(event, to) = COUNTED.any? { |name, dest| name == event && (dest.nil? || dest == to) }

  # Fires `event` from the transition's first source, with every guard of the
  # event answering true exactly for this transition's own guards — so earlier
  # transitions of the same event are skipped and this one is taken.
  def fire(event, transition, attrs)
    issue = create_issue(attrs.merge(status: transition.from.to_s, mr_iid: 1))
    take_only(issue, event, transition)
    issue.public_send(:"#{event}!")
    issue.reload
  end

  def take_only(issue, event, transition)
    own = Array(transition.opts[:guard]).map(&:to_sym)
    guards_of(event).each { |guard| issue.define_singleton_method(guard) { own.include?(guard) } }
  end

  def assert_untouched(event, transition)
    issue = fire(event, transition, EXHAUSTED.merge(dormant_recheck_at: STAMP))

    assert_equal [transition.to.to_s, 3, STAMP, 'dormant_exhausted'],
                 [issue.status, issue.dormant_recheck_count, issue.dormant_recheck_at, issue.attention_reason],
                 "#{event} #{transition.from} → #{transition.to} is not progress"
  end

  def guards_of(event)
    Issue.aasm.events.find { |e| e.name == event }.transitions.flat_map { |t| Array(t.opts[:guard]) }.map(&:to_sym)
  end

  # One incident: the failure, the audit a day later, and the retry
  # `perform_retry_errored` makes.
  def incident(issue, at:)
    fail_and_audit(issue, at: at)

    assert_equal 'error', issue.status
    assert_nil issue.attention_reason
    travel_to(at + 1.day + 1.minute) { issue.retry_pipeline! }
  end

  def fail_and_audit(issue, at:)
    travel_to(at) do
      issue.next_retry_at = nil
      issue.mark_failed!
    end
    travel_to(at + 1.day) { run_audit }
    issue.reload
  end

  def run_audit
    Autodev::DormantAudit.new(client: StubClient.new, path: PROJECT_CONFIG['path'], config: CONFIG,
                              project_config: PROJECT_CONFIG, logger: @logger).run
  end

  # One lap of the loop: the audit revives the frozen row to
  # `checking_pipeline`, and the next poll sends it back on the same green
  # pipeline. Once the row is flagged the audit leaves it where it is.
  def die_and_come_back_green(issue, at:)
    travel_to(at) { run_audit }
    return unless issue.reload.status == 'checking_pipeline'

    travel_to(at + 1.minute) { green_back_to_discussions(issue) }
  end

  class NoThreadsClient
    def merge_request_discussions(_path, _iid, **) = Gitlab::PaginatedResponse.new([])
  end

  # The `test/api_failure_is_not_a_verdict_test.rb` fixture: the real `fix`,
  # with logging and the fix cycle stubbed out.
  def bare_fixer
    MrFixer.allocate.tap do |fixer|
      { client: NoThreadsClient.new, project_path: PROJECT_CONFIG['path'], logger: @logger,
        project_config: PROJECT_CONFIG, config: CONFIG }.each { |k, v| fixer.instance_variable_set(:"@#{k}", v) }
      %i[log log_error log_activity execute_fix_cycle].each do |noop|
        fixer.define_singleton_method(noop) { |*, **| nil }
      end
    end
  end

  def green_back_to_discussions(issue)
    issue.define_singleton_method(:review_count_over_zero?) { true }
    issue.define_singleton_method(:no_unresolved_discussions?) { false }
    issue.pipeline_green!
  end
end

# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'

# Autodev #103, item 3: `safe_mark_failed!` is the single funnel every
# `error` entry goes through, and it must take the stamp decision explicitly
# rather than leave the column as it found it — leaving it as found is what
# stranded a row with an unspent budget (no stamp ever written) and, in
# 15888's mirror case, what let a stamp from a previous life (2026-05-14)
# survive into this one and make the row selected on every cycle forever.
class SafeMarkFailedDecidesTheStampTest < Minitest::Test
  include DatabaseTestHelper

  # A minimal host: just enough of DangerClaudeRunner's contract for
  # safe_mark_failed! to run standalone.
  class Runner
    include DangerClaudeRunner
  end

  def setup = setup_database

  # A logger, because a refused transition logs (Autodev #128).
  def runner = Runner.new.tap { |r| r.instance_variable_set(:@logger, StubLogger.new) }

  def active_issue(overrides = {})
    issue = create_issue({ status: 'pending' }.merge(overrides))
    issue.start_processing! # -> cloning, a mark_failed source state
    issue
  end

  # --- the guard -------------------------------------------------------

  def test_it_cannot_be_called_without_deciding_the_stamp
    issue = active_issue

    assert_raises(ArgumentError) { runner.send(:safe_mark_failed!, issue) }
  end

  # --- scheduling a retry ------------------------------------------------

  def test_a_caller_scheduling_a_retry_stamps_it
    issue = active_issue
    at = 5.minutes.from_now

    runner.send(:safe_mark_failed!, issue, next_retry_at: at)

    assert_equal 'error', issue.reload.status
    assert_in_delta at.to_i, issue.next_retry_at.to_i, 1
  end

  # --- scheduling none, deliberately --------------------------------------

  def test_a_caller_scheduling_none_clears_a_fresh_column
    issue = active_issue

    runner.send(:safe_mark_failed!, issue, next_retry_at: nil)

    assert_equal 'error', issue.reload.status
    assert_nil issue.next_retry_at
  end

  # The 15888 mirror: a stamp surviving from a previous life in `error` must
  # not survive a fresh entry that deliberately schedules nothing. Left alone,
  # `next_retry_at <= now` reads true forever, and the row is picked up on
  # every single cycle with no backoff at all.
  def test_a_caller_scheduling_none_clears_a_stale_residual_stamp
    issue = active_issue(next_retry_at: Time.zone.parse('2026-05-14 00:00:00'))

    runner.send(:safe_mark_failed!, issue, next_retry_at: nil)

    assert_nil issue.reload.next_retry_at
  end

  # --- a refused transition (Autodev #128) --------------------------------
  #
  # `whiny_transitions: false` answers a refused `mark_failed!` with `false`,
  # not an exception, so the old `rescue AASM::InvalidTransition` fallback never
  # ran and every caller went on to write its error and post its comment on a
  # row that had not moved. The answer is now the return value, and a refusal
  # writes nothing at all.

  def test_it_answers_true_when_the_row_entered_error
    assert runner.send(:safe_mark_failed!, active_issue, next_retry_at: nil)
  end

  def test_checking_pipeline_is_a_source
    issue = create_issue
    advance_to(issue, 'checking_pipeline')

    assert runner.send(:safe_mark_failed!, issue, next_retry_at: nil)
    assert_equal 'error', issue.reload.status
  end

  def test_a_refused_transition_answers_false_and_writes_nothing
    issue = parked_issue(next_retry_at: Time.zone.parse('2026-05-14 00:00:00'))

    refute runner.send(:safe_mark_failed!, issue, next_retry_at: 5.minutes.from_now)

    issue.reload

    assert_equal 'needs_clarification', issue.status
    assert_equal Time.zone.parse('2026-05-14 00:00:00'), issue.next_retry_at
  end

  # The assignment made before the event must not stay dirty on the object: the
  # next `save` anybody makes on it would write the refused decision after all.
  def test_a_refused_transition_leaves_nothing_dirty_on_the_object
    issue = parked_issue(next_retry_at: nil)

    runner.send(:safe_mark_failed!, issue, next_retry_at: 5.minutes.from_now)

    assert_nil issue.next_retry_at
    refute_predicate issue, :changed?
  end

  # At error level: the refusal is the one trace of a failure autodev chose not
  # to record, and it must reach the stream an operator watches.
  def test_a_refused_transition_says_so_in_the_log
    host = runner
    errors = []
    host.instance_variable_get(:@logger).define_singleton_method(:error) { |msg, **| errors << msg }

    host.send(:safe_mark_failed!, parked_issue(next_retry_at: nil), next_retry_at: nil)

    assert_equal 1, errors.count { |m| m.include?('refused') && m.include?('needs_clarification') }, errors.inspect
  end

  def test_the_refusal_names_the_issue
    host = runner
    issue = parked_issue(next_retry_at: nil)

    host.send(:safe_mark_failed!, issue, next_retry_at: nil)

    assert(host.instance_variable_get(:@logger).messages.any? { |m| m.include?("##{issue.issue_iid}") })
  end

  # The persisted value, not merely "some clean value": read off the object,
  # never after a reload, which would only ever show the database.
  def test_a_refused_transition_restores_the_persisted_stamp_in_memory
    stamp = Time.zone.parse('2026-05-14 00:00:00')
    issue = parked_issue(next_retry_at: stamp)

    runner.send(:safe_mark_failed!, issue, next_retry_at: 5.minutes.from_now)

    assert_equal stamp, issue.next_retry_at
    refute_predicate issue, :next_retry_at_changed?
  end

  # Only the column it assigned is put back: the caller's other unsaved state is
  # its own, and a `reload` would erase it (or raise on a deleted row).
  def test_a_refused_transition_leaves_the_callers_other_attributes_alone
    issue = parked_issue(next_retry_at: nil)
    issue.retry_count = 5

    runner.send(:safe_mark_failed!, issue, next_retry_at: nil)

    assert_equal 5, issue.retry_count
    assert_predicate issue, :retry_count_changed?
  end

  # #97 on the accepted path: a transition legal from what the object believed,
  # on a row a human has moved since, is refused loudly — never answered `false`,
  # which the callers would read as "not a failure" and walk away from silently.
  def test_a_stale_transition_still_raises
    issue = active_issue
    Issue.where(id: issue.id).update_all(status: 'closed')

    assert_raises(StaleTransitionError) { runner.send(:safe_mark_failed!, issue, next_retry_at: nil) }
    assert_equal 'closed', issue.reload.status
  end

  # The forced-`error` fallback is gone, not dormant: an `InvalidTransition`
  # (were `whiny_transitions` ever turned on) travels, and writes nothing.
  def test_an_invalid_transition_is_not_turned_into_a_forced_error
    issue = parked_issue(next_retry_at: nil)
    issue.define_singleton_method(:mark_failed!) { raise AASM::InvalidTransition.new(self, :mark_failed, :default) }

    assert_raises(AASM::InvalidTransition) { runner.send(:safe_mark_failed!, issue, next_retry_at: nil) }
    assert_equal 'needs_clarification', Issue.find(issue.id).status
  end

  private

  # `needs_clarification` is the one state outside `mark_failed`'s sources a
  # caller can still reach (IssueProcessor, after `spec_unclear!`).
  def parked_issue(next_retry_at:)
    issue = create_issue(next_retry_at: next_retry_at)
    advance_to(issue, 'checking_spec')
    issue.spec_unclear!
    issue.reload
  end
end

# frozen_string_literal: true

require_relative 'test_helper'

# Autodev #110. Every dispatch pass enqueues its whole population each cycle, so
# duplicates are normal. What makes them harmless is DISPATCHED_FROM (Autodev
# #61): the work moves the row out of the state its action was dispatched from,
# so the copy is skipped.
#
# `recheck_infra` is the one action whose precondition SURVIVES its own work — a
# recheck that finds CI still broken leaves the row `done` — which is why it
# needed a reservation and its neighbours did not. If a future action joins that
# category, this test is where somebody finds out.
class ADuplicateJobFindsNothingToDoTest < Minitest::Test
  # An action is "self-clearing" when performing it necessarily moves the row out
  # of every state it is dispatched from. Stated per action, with the transition
  # that does the moving, so adding an action forces the question to be answered.
  SELF_CLEARING = {
    process: 'IssueProcessor#process leaves PROCESSABLE_STATES on start_processing!',
    check_pipeline: 'a conclusive poll leaves checking_pipeline; an inconclusive one re-reads harmlessly',
    fix_discussions: 'a round ends on discussions_fixed! or an abandon, leaving fixing_discussions',
    post_completion: 'the hook transitions through running_post_completion',
    retry_errored: 'retry_pipeline! / retry_processing! leave error',
    retry_stuck: 'IssueProcessor#process leaves pending'
  }.freeze

  # The exception, and the reason it needs a reservation instead.
  RESERVED = {
    recheck_infra: 'a recheck that does not recover leaves the row `done`, so the ' \
                   'state guard cannot tell a duplicate apart — PollDispatcher#reserve_infra_recheck? does'
  }.freeze

  def test_every_dispatched_action_is_declared_self_clearing_or_reserved
    declared = SELF_CLEARING.keys + RESERVED.keys

    assert_equal IssueProcessJob::DISPATCHED_FROM.keys.sort, declared.sort,
                 'a new action must declare whether its precondition survives its own work'
  end

  def test_the_reserved_action_is_reserved_by_the_dispatcher
    assert Autodev::PollDispatcher.private_method_defined?(:reserve_infra_recheck?),
           'recheck_infra is declared as reserved, so the reservation must exist'
  end
end

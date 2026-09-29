# frozen_string_literal: true

require_relative 'test_helper'

# Autodev #110. Every dispatch pass enqueues its whole population each cycle, so
# duplicates are normal. What makes most of them harmless is DISPATCHED_FROM
# (Autodev #61): the work moves the row out of the state its action was
# dispatched from, so the copy is skipped.
#
# `recheck_infra` is the one action where a surviving precondition costs a real
# budget unit — a recheck that finds CI still broken leaves the row `done`, so a
# duplicate spends another attempt (`9/5`) — which is why it needed a
# reservation. `post_completion`'s precondition survives too — found by the
# branch review of #110, whose spec's enumeration omitted it, which is exactly
# how the false "recheck_infra is the *one* action" claim got through — and it
# was first declared LATENT: no budget to overspend. Autodev #114 reserved it
# instead, because the cost was not a budget but a deploy re-run on every cycle.
# If a future action joins either category, this test is where somebody finds
# out.
class ADuplicateJobFindsNothingToDoTest < Minitest::Test
  # An action is "self-clearing" when performing it necessarily moves the row out
  # of every state it is dispatched from. Stated per action, with the transition
  # that does the moving, so adding an action forces the question to be answered.
  SELF_CLEARING = {
    process: 'IssueProcessor#process leaves PROCESSABLE_STATES on start_processing!',
    check_pipeline: 'a conclusive poll leaves checking_pipeline; an inconclusive one re-reads harmlessly',
    fix_discussions: 'a round ends on discussions_fixed! or an abandon, leaving fixing_discussions',
    retry_errored: 'retry_pipeline! / retry_processing! leave error — except while ' \
                   '`handed_over?` keeps declining on an unreadable GitLab read (Autodev #102): ' \
                   'the row stays in `error` with `next_retry_at` unchanged, so `dispatch_retries` ' \
                   're-enqueues it every cycle for as long as the read keeps failing. Not RESERVED: ' \
                   '`retry_count` is only ever *incremented* by `mark_failed` (the two other ' \
                   'writers, `Issue.reset_for_retry!` and the dormant audit, reset it to 0), ' \
                   'and never by this pass, so nothing is ' \
                   'overspent — the recurring cost is one extra GitLab read per cycle, not a budget ' \
                   'unit, and the row self-clears the moment the read succeeds',
    retry_stuck: 'IssueProcessor#process leaves pending'
  }.freeze

  # The exceptions, and the reason each needs a reservation instead.
  RESERVED = {
    recheck_infra: 'a recheck that does not recover leaves the row `done`, so the ' \
                   'state guard cannot tell a duplicate apart — PollDispatcher#reserve_infra_recheck? does',
    post_completion: 'start_post_completion! -> post_completion_done! returns the row to `done`, and neither ' \
                     'GitLab gate of dispatch_done_unassigned is moved by a deploy, so the pass re-ran the ' \
                     'command every cycle (Autodev #114) — PollDispatcher#reserve_post_completion? stamps ' \
                     'post_completion_dispatched_at once per delivery'
  }.freeze

  # What this guard proves is that every action is **declared**, never that a
  # declaration is **true** (the `test/api_failure_is_not_a_verdict_test.rb` /
  # `test/i18n_derived_keys_test.rb` limit): the reason is an English sentence
  # nothing verifies, which is exactly how `post_completion` survived under
  # SELF_CLEARING — a declaration that read as true and was not. The behaviour
  # behind each RESERVED entry is held by its own file
  # (`test/infra_recheck_reservation_test.rb`, `test/post_completion_runs_once_test.rb`).
  def test_every_dispatched_action_is_declared_self_clearing_reserved_or_latent
    declared = SELF_CLEARING.keys + RESERVED.keys

    assert_equal IssueProcessJob::DISPATCHED_FROM.keys.sort, declared.sort,
                 'a new action must declare whether its precondition survives its own work'
  end

  def test_the_reserved_actions_are_reserved_by_the_dispatcher
    assert Autodev::PollDispatcher.private_method_defined?(:reserve_infra_recheck?),
           'recheck_infra is declared as reserved, so the reservation must exist'
    assert Autodev::PollDispatcher.private_method_defined?(:reserve_post_completion?),
           'post_completion is declared as reserved, so the reservation must exist'
  end
end

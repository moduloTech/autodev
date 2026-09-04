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
# reservation. `post_completion`'s precondition survives too (see LATENT below),
# but there is no budget there to overspend, so it needed no reservation; this
# is the branch review's own correction (my spec's enumeration omitted it,
# which is exactly how the false "recheck_infra is the *one* action" claim got
# through). If a future action joins either category, this test is where
# somebody finds out.
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
                   '`retry_count` is written by `mark_failed`, not by this pass, so nothing is ' \
                   'overspent — the recurring cost is one extra GitLab read per cycle, not a budget ' \
                   'unit, and the row self-clears the moment the read succeeds',
    retry_stuck: 'IssueProcessor#process leaves pending'
  }.freeze

  # The exception, and the reason it needs a reservation instead.
  RESERVED = {
    recheck_infra: 'a recheck that does not recover leaves the row `done`, so the ' \
                   'state guard cannot tell a duplicate apart — PollDispatcher#reserve_infra_recheck? does'
  }.freeze

  # A third category, found by branch review and not by this file's first
  # version: `post_completion`'s precondition ALSO survives its own work.
  # `start_post_completion!` -> `post_completion_done!` (`app/models/issue.rb:
  # 117-118`) returns the row to `done`, and `dispatch_done_unassigned`'s own
  # gates (`still_assigned?`, `mr_state_defers_hook?`) are unaffected by that
  # round trip, so a duplicate job is NOT skipped by DISPATCHED_FROM — the pass
  # re-runs the deploy command every poll interval it is still unassigned.
  #
  # Not RESERVED like `recheck_infra`, because there is no budget here to
  # overspend: no counter, no cap, no `9/5`-shaped harm — just a repeated
  # `post_completion` command. And latent rather than fixed: no configured
  # project declares `post_completion` (CLAUDE.md), so the defect has never
  # fired in production. Tracked as its own ticket, out of scope here.
  LATENT = {
    post_completion: 'start_post_completion! -> post_completion_done! returns the row to `done`; ' \
                     'no budget to overspend, so no 9/5-shaped harm — latent because no project ' \
                     'configures the hook, and fixed under a separate ticket'
  }.freeze

  # What this guard proves is that every action is **declared**, never that a
  # declaration is **true** (the `test/api_failure_is_not_a_verdict_test.rb` /
  # `test/i18n_derived_keys_test.rb` limit): the reason is an English sentence
  # nothing verifies, which is exactly how `post_completion` survived under
  # SELF_CLEARING — a declaration that read as true and was not.
  def test_every_dispatched_action_is_declared_self_clearing_reserved_or_latent
    declared = SELF_CLEARING.keys + RESERVED.keys + LATENT.keys

    assert_equal IssueProcessJob::DISPATCHED_FROM.keys.sort, declared.sort,
                 'a new action must declare whether its precondition survives its own work'
  end

  def test_the_reserved_action_is_reserved_by_the_dispatcher
    assert Autodev::PollDispatcher.private_method_defined?(:reserve_infra_recheck?),
           'recheck_infra is declared as reserved, so the reservation must exist'
  end
end

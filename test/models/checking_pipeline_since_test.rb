# frozen_string_literal: true

require_relative '../test_helper'

# The clock behind the absolute age bound on a pipeline watch (Autodev #53).
#
# `issues.checking_pipeline_since` holds the instant the row entered
# `checking_pipeline`, NULL everywhere else, and is written by a single AASM
# callback so "reset on any transition" needs no clear at each of the six exits
# — which is exactly the semantics the ticket asks for: N days *without a
# transition*.
#
# It is deliberately not `pipeline_poll_since`: that column is a display string
# reset by `clear_pipeline_poll_since` whenever a poll resolves to green or red,
# including the infra-red case that stays in the state — so it measures
# consecutive unresolved polls, the one quantity that never bounds an infra loop.
class CheckingPipelineSinceTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
  end

  def watched
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue
  end

  def test_entering_checking_pipeline_stamps_the_clock
    assert_operator watched.checking_pipeline_since, :>, 1.minute.ago
  end

  # Persisted by the same UPDATE as the status: the callback is ordered before
  # `persist_status_change!`, so nothing has to remember a second save.
  def test_the_stamp_is_persisted_not_just_assigned
    refute_nil watched.reload.checking_pipeline_since
  end

  def test_no_earlier_state_is_stamped
    issue = create_issue
    advance_to(issue, 'implementing')

    assert_nil issue.checking_pipeline_since
  end

  def test_leaving_for_reviewing_clears_the_clock
    issue = watched
    issue._review_count_zero = true
    issue.pipeline_green!

    assert_nil issue.reload.checking_pipeline_since
  end

  def test_leaving_for_fixing_pipeline_clears_the_clock
    issue = watched
    issue.pipeline_failed_code!

    assert_nil issue.reload.checking_pipeline_since
  end

  # The clock restarts on re-entry: a row that ping-pongs through a fix cycle is
  # moving, and is bounded by stagnation detection rather than by this.
  def test_re_entering_restamps_the_clock
    issue = watched
    issue.update_columns(checking_pipeline_since: 40.days.ago)
    issue._review_count_over_zero = true
    issue._unresolved_discussions_empty = false
    issue.pipeline_green!
    issue.discussions_fixed!

    assert_operator issue.reload.checking_pipeline_since, :>, 1.minute.ago
  end

  # `revive_stalled!` and `reset_for_retry!` set the status with `update_all`,
  # bypassing AASM — they leave the column NULL, and PollTracker seeds it at the
  # first poll. Pinned so the lazy stamp keeps a reason to exist.
  def test_a_row_revived_by_update_all_carries_no_stamp
    issue = create_issue(status: 'reviewing', mr_iid: 5)
    Issue.revive_stalled!(Issue.where(id: issue.id))

    assert_equal ['checking_pipeline', nil],
                 [issue.reload.status, issue.checking_pipeline_since]
  end

  # The lazy stamp only fills a NULL (`PollTracker#seed_watch_clock`), so the
  # two `update_all` entries must arrive at NULL — they cannot inherit whatever
  # the row was carrying. Not every exit from `checking_pipeline` clears the
  # column: the ones that bypass AASM with a direct `update` leave it set, and
  # `handle_stagnation` is one of them. Without this, an operator pressing
  # Reset on a long-dead stagnation row hands it a months-old clock and the age
  # bound abandons it at the very next poll — the reset silently undone.
  def test_a_row_reset_by_an_operator_starts_a_fresh_clock
    issue = create_issue(status: 'done', mr_iid: 5)
    issue.update_columns(checking_pipeline_since: 200.days.ago)

    Issue.reset_for_retry!(Issue.where(id: issue.id), reset_budget: true, clear_attention: true)

    assert_equal ['checking_pipeline', nil],
                 [issue.reload.status, issue.checking_pipeline_since]
  end
end

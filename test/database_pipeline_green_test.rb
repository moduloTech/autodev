# frozen_string_literal: true

require_relative 'test_helper'

class DatabasePipelineGreenTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
  end

  # -- review_count == 0: pipeline green → reviewing --

  def test_pipeline_green_review_count_zero_goes_to_reviewing
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue._review_count_zero = true
    issue.pipeline_green!

    assert_equal 'reviewing', issue.status
  end

  # -- review_count > 0: no discussions → done --

  def test_pipeline_green_review_count_over_zero_no_discussions_goes_to_done
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue._review_count_over_zero = true
    issue._unresolved_discussions_empty = true
    issue.pipeline_green!

    assert_equal 'done', issue.status
  end

  # -- review_count > 0: with discussions → fixing_discussions --

  def test_pipeline_green_review_count_over_zero_with_discussions_goes_to_fixing_discussions
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue._review_count_over_zero = true
    issue._unresolved_discussions_empty = false
    issue.pipeline_green!

    assert_equal 'fixing_discussions', issue.status
  end

  # -- max review rounds reached → done, via `abandon`, not `pipeline_green` --
  #
  # `pipeline_green` used to carry a second transition to `done`, guarded by
  # `max_review_rounds_reached?`. That made a give-up look like a delivery in the
  # journal and in the audit log, and it was one of the two ways into `done` from
  # `checking_pipeline` that Autodev #60 collapsed into `abandon`.

  def test_reaching_the_review_round_limit_is_an_abandon_not_a_green_completion
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue.abandon!

    assert_equal 'done', issue.status
  end

  # No guard flags set: `pipeline_green!` has nothing left to do from
  # `checking_pipeline` when the review counters say nothing, and
  # `whiny_transitions: false` makes that a no-op rather than a raise.
  def test_pipeline_green_no_longer_reaches_done_on_its_own
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue.pipeline_green!

    assert_equal 'checking_pipeline', issue.status
  end

  # -- review_done! → checking_pipeline --

  def test_review_done_goes_to_checking_pipeline
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue._review_count_zero = true
    issue.pipeline_green!

    assert_equal 'reviewing', issue.status
    issue.review_done!

    assert_equal 'checking_pipeline', issue.status
  end

  # -- post_completion (triggered by poller, not by pipeline_green) --

  def test_start_post_completion_from_done
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue._review_count_over_zero = true
    issue._unresolved_discussions_empty = true
    issue.pipeline_green!

    assert_equal 'done', issue.status
    issue.start_post_completion!

    assert_equal 'running_post_completion', issue.status
  end

  def test_post_completion_done_goes_to_done
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue._review_count_over_zero = true
    issue._unresolved_discussions_empty = true
    issue.pipeline_green!
    issue.start_post_completion!

    assert_equal 'running_post_completion', issue.status
    issue.post_completion_done!

    assert_equal 'done', issue.status
  end

  # -- Guard priority: review_count_zero takes precedence --

  def test_review_count_zero_takes_precedence_over_review_count_over_zero
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue._review_count_zero = true
    issue._review_count_over_zero = true
    issue._unresolved_discussions_empty = false
    issue.pipeline_green!

    assert_equal 'reviewing', issue.status
  end

  # `abandon` is legal from `fixing_discussions` too — that is the discussion
  # stagnation path (MrFixer#transition_to_done_stagnation!).
  def test_abandon_is_legal_from_fixing_discussions
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue._review_count_over_zero = true
    issue._unresolved_discussions_empty = false
    issue.pipeline_green!
    issue.abandon!

    assert_equal 'done', issue.status
  end

  # And illegal everywhere else: an abandon is a give-up on work in flight, and
  # `whiny_transitions: false` would otherwise let `abandon_issue` run its GitLab
  # side effects after a no-op (the Autodev #61 shape).
  def test_abandon_is_a_no_op_from_a_terminal_state
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue.abandon!

    refute issue.abandon!
    assert_equal 'done', issue.status
  end
end

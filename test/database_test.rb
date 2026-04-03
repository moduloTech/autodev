# frozen_string_literal: true

require_relative 'test_helper'

class DatabaseStateTransitionsTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
  end

  # -- Happy path --

  def test_happy_path_pending_to_checking_spec
    issue = create_issue

    assert_equal 'pending', issue.status

    issue.start_processing!

    assert_equal 'cloning', issue.status

    issue.clone_complete!

    assert_equal 'checking_spec', issue.status
  end

  def test_happy_path_implementing_to_creating_mr
    issue = create_issue
    advance_to(issue, 'checking_spec')
    issue.spec_clear!

    assert_equal 'implementing', issue.status

    issue.impl_complete!

    assert_equal 'committing', issue.status

    issue.commit_complete!

    assert_equal 'pushing', issue.status
  end

  def test_happy_path_pushing_to_checking_pipeline
    issue = create_issue
    advance_to(issue, 'pushing')
    issue.push_complete!

    assert_equal 'creating_mr', issue.status

    issue.mr_created!

    assert_equal 'reviewing', issue.status

    issue.review_complete!

    assert_equal 'checking_pipeline', issue.status
  end

  # -- Clone guards --

  def test_clone_complete_with_issue_closed_goes_to_over
    issue = create_issue
    advance_to(issue, 'cloning')
    issue._issue_closed = true
    issue.clone_complete!

    assert_equal 'over', issue.status
  end

  def test_clone_complete_with_skip_to_mr_goes_to_creating_mr
    issue = create_issue
    advance_to(issue, 'cloning')
    issue._skip_to_mr = true
    issue.clone_complete!

    assert_equal 'creating_mr', issue.status
  end

  def test_clone_complete_default_goes_to_checking_spec
    issue = create_issue
    advance_to(issue, 'cloning')
    issue.clone_complete!

    assert_equal 'checking_spec', issue.status
  end

  # -- Spec check paths --

  def test_spec_unclear_to_needs_clarification
    issue = create_issue
    advance_to(issue, 'checking_spec')
    issue.spec_unclear!

    assert_equal 'needs_clarification', issue.status
  end

  def test_clarification_received_returns_to_pending
    issue = create_issue
    advance_to(issue, 'checking_spec')
    issue.spec_unclear!
    issue.clarification_received!

    assert_equal 'pending', issue.status
  end

  def test_question_detected_to_answering_question
    issue = create_issue
    advance_to(issue, 'checking_spec')
    issue.question_detected!

    assert_equal 'answering_question', issue.status
  end

  def test_question_answered_to_over
    issue = create_issue
    advance_to(issue, 'checking_spec')
    issue.question_detected!
    issue.question_answered!

    assert_equal 'over', issue.status
  end

  # -- Pipeline green guards --

  def test_pipeline_green_no_discussions_no_post_completion_goes_to_over
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue._unresolved_discussions_empty = true
    issue._post_completion = false
    issue.pipeline_green!

    assert_equal 'over', issue.status
  end

  def test_pipeline_green_no_discussions_with_post_completion_goes_to_running_post_completion
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue._unresolved_discussions_empty = true
    issue._post_completion = true
    issue.pipeline_green!

    assert_equal 'running_post_completion', issue.status
  end

  def test_pipeline_green_with_discussions_under_max_rounds_goes_to_fixing_discussions
    issue = create_issue(fix_round: 0)
    advance_to(issue, 'checking_pipeline')
    issue._unresolved_discussions_empty = false
    issue._max_fix_rounds = 3
    issue._post_completion = false
    issue.pipeline_green!

    assert_equal 'fixing_discussions', issue.status
  end

  def test_pipeline_green_with_discussions_at_max_rounds_goes_to_over
    issue = create_issue(fix_round: 3)
    advance_to(issue, 'checking_pipeline')
    issue._unresolved_discussions_empty = false
    issue._max_fix_rounds = 3
    issue._post_completion = false
    issue.pipeline_green!

    assert_equal 'over', issue.status
  end

  def test_pipeline_green_with_discussions_at_max_rounds_with_post_completion
    issue = create_issue(fix_round: 3)
    advance_to(issue, 'checking_pipeline')
    issue._unresolved_discussions_empty = false
    issue._max_fix_rounds = 3
    issue._post_completion = true
    issue.pipeline_green!

    assert_equal 'running_post_completion', issue.status
  end

  def test_post_completion_done_goes_to_over
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue._unresolved_discussions_empty = true
    issue._post_completion = true
    issue.pipeline_green!

    assert_equal 'running_post_completion', issue.status
    issue.post_completion_done!

    assert_equal 'over', issue.status
  end

  # -- Pipeline failure paths --

  def test_pipeline_failed_code_can_fix_goes_to_fixing_pipeline
    issue = create_issue(fix_round: 0)
    advance_to(issue, 'checking_pipeline')
    issue._max_fix_rounds = 3
    issue.pipeline_failed_code!

    assert_equal 'fixing_pipeline', issue.status
  end

  def test_pipeline_failed_code_cannot_fix_goes_to_blocked
    issue = create_issue(fix_round: 3)
    advance_to(issue, 'checking_pipeline')
    issue._max_fix_rounds = 3
    issue.pipeline_failed_code!

    assert_equal 'blocked', issue.status
  end

  def test_pipeline_failed_infra_goes_to_blocked
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue.pipeline_failed_infra!

    assert_equal 'blocked', issue.status
  end

  def test_pipeline_canceled_goes_to_blocked
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue.pipeline_canceled!

    assert_equal 'blocked', issue.status
  end

  # -- Fix cycles --

  def test_discussions_fixed_goes_to_checking_pipeline
    issue = create_issue(fix_round: 0)
    advance_to(issue, 'checking_pipeline')
    issue._unresolved_discussions_empty = false
    issue._max_fix_rounds = 3
    issue._post_completion = false
    issue.pipeline_green!

    assert_equal 'fixing_discussions', issue.status
    issue.discussions_fixed!

    assert_equal 'checking_pipeline', issue.status
  end

  def test_pipeline_fix_done_goes_to_checking_pipeline
    issue = create_issue(fix_round: 0)
    advance_to(issue, 'checking_pipeline')
    issue._max_fix_rounds = 3
    issue.pipeline_failed_code!

    assert_equal 'fixing_pipeline', issue.status
    issue.pipeline_fix_done!

    assert_equal 'checking_pipeline', issue.status
  end

  # -- Resume events --

  def test_resume_todo_from_over_goes_to_pending
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue._unresolved_discussions_empty = true
    issue._post_completion = false
    issue.pipeline_green!

    assert_equal 'over', issue.status
    issue.resume_todo!

    assert_equal 'pending', issue.status
  end

  def test_resume_mr_from_over_goes_to_fixing_discussions
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue._unresolved_discussions_empty = true
    issue._post_completion = false
    issue.pipeline_green!

    assert_equal 'over', issue.status
    issue.resume_mr!

    assert_equal 'fixing_discussions', issue.status
  end

  # -- Error handling --

  def test_mark_failed_from_implementing_goes_to_error
    issue = create_issue
    advance_to(issue, 'checking_spec')
    issue.spec_clear!

    assert_equal 'implementing', issue.status
    issue.mark_failed!

    assert_equal 'error', issue.status
  end

  def test_retry_processing_from_error_goes_to_pending
    issue = create_issue
    advance_to(issue, 'checking_spec')
    issue.spec_clear!
    issue.mark_failed!
    issue.retry_processing!

    assert_equal 'pending', issue.status
  end

  def test_retry_pipeline_from_error_goes_to_checking_pipeline
    issue = create_issue
    advance_to(issue, 'checking_spec')
    issue.spec_clear!
    issue.mark_failed!
    issue.retry_pipeline!

    assert_equal 'checking_pipeline', issue.status
  end

  # -- Invalid transitions --

  def test_invalid_transition_returns_false
    issue = create_issue
    # pending cannot receive pipeline_green!
    issue.pipeline_green!

    assert_equal 'pending', issue.status
  end

  # -- Guard boundary: can_fix? --

  def test_can_fix_boundary
    issue = create_issue(fix_round: 2)
    advance_to(issue, 'checking_pipeline')
    issue._max_fix_rounds = 3

    assert_predicate issue, :can_fix?
    refute_predicate issue, :max_fix_rounds_reached?

    issue.pipeline_failed_code!

    assert_equal 'fixing_pipeline', issue.status
  end

  def test_cannot_fix_at_max
    issue = create_issue(fix_round: 3)
    advance_to(issue, 'checking_pipeline')
    issue._max_fix_rounds = 3

    refute_predicate issue, :can_fix?
    assert_predicate issue, :max_fix_rounds_reached?

    issue.pipeline_failed_code!

    assert_equal 'blocked', issue.status
  end

  # -- Persistence callback --

  def test_transitions_persist_to_database
    issue = create_issue
    issue.start_processing!

    reloaded = Issue.where(id: issue.id).first

    assert_equal 'cloning', reloaded.status
  end
end

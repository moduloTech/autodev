# frozen_string_literal: true

require_relative 'test_helper'

class DatabaseAdvancedTransitionsTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
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
end

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
end

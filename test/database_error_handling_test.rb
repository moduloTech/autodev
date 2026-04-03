# frozen_string_literal: true

require_relative 'test_helper'

class DatabaseErrorHandlingTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
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

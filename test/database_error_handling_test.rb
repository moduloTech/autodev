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

  # -- Mark failed from reviewing --

  def test_mark_failed_from_reviewing
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue._review_count_zero = true
    issue.pipeline_green!

    assert_equal 'reviewing', issue.status
    issue.mark_failed!

    assert_equal 'error', issue.status
  end

  # -- Persistence callback --

  def test_transitions_persist_to_database
    issue = create_issue
    issue.start_processing!

    reloaded = Issue.where(id: issue.id).first

    assert_equal 'cloning', reloaded.status
  end
end

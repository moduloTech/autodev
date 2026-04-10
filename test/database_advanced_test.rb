# frozen_string_literal: true

require_relative 'test_helper'

class DatabaseAdvancedTransitionsTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
  end

  # -- Pipeline failure paths --

  def test_pipeline_failed_code_goes_to_fixing_pipeline
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue.pipeline_failed_code!

    assert_equal 'fixing_pipeline', issue.status
  end

  # -- Fix cycles --

  def test_discussions_fixed_goes_to_checking_pipeline
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue._review_count_over_zero = true
    issue._unresolved_discussions_empty = false
    issue.pipeline_green!

    assert_equal 'fixing_discussions', issue.status
    issue.discussions_fixed!

    assert_equal 'checking_pipeline', issue.status
  end

  def test_pipeline_fix_done_goes_to_checking_pipeline
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue.pipeline_failed_code!

    assert_equal 'fixing_pipeline', issue.status
    issue.pipeline_fix_done!

    assert_equal 'checking_pipeline', issue.status
  end

  # -- Reentry event --

  def test_reenter_from_done_goes_to_pending
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue._review_count_over_zero = true
    issue._unresolved_discussions_empty = true
    issue.pipeline_green!

    assert_equal 'done', issue.status
    issue.reenter!

    assert_equal 'pending', issue.status
  end
end

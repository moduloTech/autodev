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

  # -- max review rounds reached → done --

  def test_pipeline_green_max_review_rounds_reached_goes_to_done
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue._max_review_rounds_reached = true
    issue.pipeline_green!

    assert_equal 'done', issue.status
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

  # -- Guard priority: max_review_rounds_reached takes precedence --

  def test_max_review_rounds_takes_precedence_over_review_count_over_zero
    issue = create_issue
    advance_to(issue, 'checking_pipeline')
    issue._max_review_rounds_reached = true
    issue._review_count_over_zero = true
    issue._unresolved_discussions_empty = false
    issue.pipeline_green!

    assert_equal 'done', issue.status
  end
end

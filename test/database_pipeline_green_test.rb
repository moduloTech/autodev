# frozen_string_literal: true

require_relative 'test_helper'

class DatabasePipelineGreenTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
  end

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
end

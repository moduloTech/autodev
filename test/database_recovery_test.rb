# frozen_string_literal: true

require_relative 'test_helper'

class DatabaseRecoveryTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
  end

  def test_recover_error_with_mr_to_checking_pipeline
    Issue.create(project_path: 'g/p', issue_iid: 1001, status: 'error', mr_iid: 42, retry_count: 0)
    count = Database.recover_on_startup!(max_retries: 3)

    assert_equal 1, count
    assert_equal 'checking_pipeline', Issue.first.status
  end

  def test_recover_error_without_mr_to_pending
    Issue.create(project_path: 'g/p', issue_iid: 1002, status: 'error', mr_iid: nil, retry_count: 0)
    count = Database.recover_on_startup!(max_retries: 3)

    assert_equal 1, count
    assert_equal 'pending', Issue.first.status
  end

  def test_does_not_recover_when_max_retries_exceeded
    Issue.create(project_path: 'g/p', issue_iid: 1003, status: 'error', retry_count: 3)
    count = Database.recover_on_startup!(max_retries: 3)

    assert_equal 0, count
    assert_equal 'error', Issue.first.status
  end

  def test_does_not_recover_when_next_retry_at_in_future
    Issue.create(project_path: 'g/p', issue_iid: 1004, status: 'error', retry_count: 0,
                 next_retry_at: Sequel.lit("datetime('now', '+1 hour')"))
    count = Database.recover_on_startup!(max_retries: 3)

    assert_equal 0, count
    assert_equal 'error', Issue.first.status
  end

  def test_recover_fixing_pipeline_to_checking_pipeline
    Issue.create(project_path: 'g/p', issue_iid: 1005, status: 'fixing_pipeline')
    count = Database.recover_on_startup!(max_retries: 3)

    assert_equal 1, count
    assert_equal 'checking_pipeline', Issue.first.status
  end

  def test_recover_reviewing_to_checking_pipeline
    Issue.create(project_path: 'g/p', issue_iid: 1006, status: 'reviewing')
    count = Database.recover_on_startup!(max_retries: 3)

    assert_equal 1, count
    assert_equal 'checking_pipeline', Issue.first.status
  end

  def test_recover_running_post_completion_to_done
    Issue.create(project_path: 'g/p', issue_iid: 1007, status: 'running_post_completion')
    count = Database.recover_on_startup!(max_retries: 3)

    assert_equal 1, count
    issue = Issue.first

    assert_equal 'done', issue.status
    refute_nil issue.finished_at
  end

  def test_recover_stuck_active_states_to_pending
    %w[cloning checking_spec implementing committing pushing creating_mr].each_with_index do |state, i|
      Issue.create(project_path: 'g/p', issue_iid: 2001 + i, status: state)
    end
    count = Database.recover_on_startup!(max_retries: 3)

    assert_equal 6, count
    Issue.all.each do |issue|
      assert_equal 'pending', issue.status
    end
  end
end

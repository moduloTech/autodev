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

  def test_recover_running_post_completion_to_over
    Issue.create(project_path: 'g/p', issue_iid: 1006, status: 'running_post_completion')
    count = Database.recover_on_startup!(max_retries: 3)

    assert_equal 1, count
    issue = Issue.first

    assert_equal 'over', issue.status
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

  def test_migrate_mr_pipeline_running_to_checking_pipeline
    insert_raw(3001, 'mr_pipeline_running')
    Database.migrate_statuses!

    assert_equal 'checking_pipeline', raw_status(3001)
  end

  def test_migrate_mr_fixing_to_fixing_discussions
    insert_raw(3002, 'mr_fixing')
    Database.migrate_statuses!

    assert_equal 'fixing_discussions', raw_status(3002)
  end

  def test_migrate_mr_pipeline_fixing_to_fixing_pipeline
    insert_raw(3003, 'mr_pipeline_fixing')
    Database.migrate_statuses!

    assert_equal 'fixing_pipeline', raw_status(3003)
  end

  def test_migrate_statuses_done_with_mr_to_checking_pipeline
    insert_raw(4001, 'done', mr_iid: 42)
    Database.migrate_statuses!

    assert_equal 'checking_pipeline', raw_status(4001)
  end

  def test_migrate_statuses_done_without_mr_to_over
    insert_raw(4002, 'done')
    Database.migrate_statuses!

    assert_equal 'over', raw_status(4002)
  end

  private

  def insert_raw(iid, status, **extra)
    Database.db[:issues].insert({ project_path: 'g/p', issue_iid: iid, status: status }.merge(extra))
  end

  def raw_status(iid)
    Database.db[:issues].where(issue_iid: iid).first[:status]
  end
end

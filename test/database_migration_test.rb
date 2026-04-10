# frozen_string_literal: true

require_relative 'test_helper'

class DatabaseMigrationTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
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

  def test_migrate_statuses_done_with_mr_stays_done
    insert_raw(4001, 'done', mr_iid: 42)
    Database.migrate_statuses!

    assert_equal 'done', raw_status(4001)
  end

  def test_migrate_statuses_done_without_mr_to_done
    insert_raw(4002, 'done')
    Database.migrate_statuses!

    assert_equal 'done', raw_status(4002)
  end

  def test_migrate_over_to_done
    insert_raw(4003, 'over')
    Database.migrate_statuses!

    assert_equal 'done', raw_status(4003)
  end

  def test_migrate_blocked_to_pending
    insert_raw(4004, 'blocked')
    Database.migrate_statuses!

    assert_equal 'pending', raw_status(4004)
  end

  private

  def insert_raw(iid, status, **extra)
    Database.db[:issues].insert({ project_path: 'g/p', issue_iid: iid, status: status }.merge(extra))
  end

  def raw_status(iid)
    Database.db[:issues].where(issue_iid: iid).first[:status]
  end
end

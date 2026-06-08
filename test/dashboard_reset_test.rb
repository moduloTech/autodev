# frozen_string_literal: true

require_relative 'autodev_test_helper'

# Tests for Dashboard.reset.
class DashboardResetTest < Minitest::Test
  include DatabaseTestHelper
  include StubDatabaseConnect

  def setup
    setup_database
    super
    @pastel = FakePastel.new
  end

  def test_no_errors_to_reset
    out = capture_io { Dashboard.reset({ 'database_url' => 'sqlite://:memory:' }, @pastel) }.first

    assert_match(/Aucune issue en erreur/, out)
  end

  def test_no_errors_for_specific_iid
    config = { 'database_url' => 'sqlite://:memory:', 'reset_iid' => 999 }
    out = capture_io { Dashboard.reset(config, @pastel) }.first

    assert_match(/Issue #999 non trouvée/, out)
  end

  def test_resets_all_errors_message
    create_issue(issue_iid: 800, status: 'error', error_message: 'fail1', retry_count: 2,
                 next_retry_at: Time.now.to_s)
    create_issue(issue_iid: 801, status: 'error', error_message: 'fail2', retry_count: 1,
                 next_retry_at: Time.now.to_s)

    out = capture_io { Dashboard.reset({ 'database_url' => 'sqlite://:memory:' }, @pastel) }.first

    assert_match(/2 issue\(s\) remise\(s\) en pending/, out)
  end

  def test_resets_all_errors_db_state
    create_issue(issue_iid: 800, status: 'error', error_message: 'fail1', retry_count: 2,
                 next_retry_at: Time.now.to_s)
    capture_io { Dashboard.reset({ 'database_url' => 'sqlite://:memory:' }, @pastel) }

    assert_equal 'pending', Issue.find_by(issue_iid: 800).status
    assert_equal 0, Issue.find_by(issue_iid: 800).retry_count
    assert_nil Issue.find_by(issue_iid: 800).error_message
  end

  def test_resets_specific_iid
    create_issue(issue_iid: 810, status: 'error', error_message: 'fail', retry_count: 3)
    create_issue(issue_iid: 811, status: 'error', error_message: 'other fail', retry_count: 1)

    config = { 'database_url' => 'sqlite://:memory:', 'reset_iid' => 810 }
    capture_io { Dashboard.reset(config, @pastel) }

    assert_equal 'pending', Issue.find_by(issue_iid: 810).status
    assert_equal 'error', Issue.find_by(issue_iid: 811).status
  end

  def test_does_not_reset_blocked
    # `blocked` is a legacy status value not in AASM's state list — AR
    # would reject it on `.create`, so we INSERT directly to mimic an
    # old prod row pre-status-migration.
    ActiveRecord::Base.connection.execute(
      'INSERT INTO issues (project_path, issue_iid, status, error_message, created_at) ' \
      "VALUES ('g/p', 820, 'blocked', 'infra', datetime('now'))"
    )

    out = capture_io { Dashboard.reset({ 'database_url' => 'sqlite://:memory:' }, @pastel) }.first

    assert_match(/Aucune issue en erreur/, out)
    assert_equal 'blocked', Issue.find_by(issue_iid: 820).status
  end
end

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

    assert_match(/2 issue\(s\) relancée\(s\)/, out)
  end

  def test_resets_pre_mr_error_to_pending_with_next_retry_stamped
    # A pre-MR error (no mr_iid) restarts as pending. next_retry_at MUST be
    # stamped, otherwise dispatch_retries skips it and the row is orphaned in
    # pending forever (task #26 — the GitLab label is still label_doing so
    # dispatch_new_issues never re-discovers it either).
    create_issue(issue_iid: 800, status: 'error', error_message: 'fail1', retry_count: 2)
    capture_io { Dashboard.reset({ 'database_url' => 'sqlite://:memory:' }, @pastel) }

    issue = Issue.find_by(issue_iid: 800)

    assert_equal 'pending', issue.status
    assert_nil issue.error_message
    refute_nil issue.next_retry_at, 'next_retry_at must be stamped so dispatch_retries re-enqueues it'
  end

  def test_resets_error_with_mr_to_checking_pipeline
    # An error that already produced an MR resumes at checking_pipeline, where
    # dispatch_pipelines picks it up — no need to re-implement from scratch.
    create_issue(issue_iid: 805, status: 'error', error_message: 'pipeline fail', mr_iid: 4321)
    capture_io { Dashboard.reset({ 'database_url' => 'sqlite://:memory:' }, @pastel) }

    assert_equal 'checking_pipeline', Issue.find_by(issue_iid: 805).status
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

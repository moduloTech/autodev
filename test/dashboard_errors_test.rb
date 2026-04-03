# frozen_string_literal: true

require_relative 'autodev_test_helper'

# Tests for Dashboard.show_errors.
class DashboardErrorsTest < Minitest::Test
  include DatabaseTestHelper
  include StubDatabaseConnect

  def setup
    setup_database
    super
  end

  def test_no_errors_message
    out = capture_io { Dashboard.show_errors({ 'database_url' => 'sqlite://:memory:' }) }.first

    assert_match(/Aucune issue en erreur/, out)
  end

  def test_no_errors_for_specific_iid
    out = capture_io { Dashboard.show_errors({ 'database_url' => 'sqlite://:memory:', 'errors_iid' => 999 }) }.first

    assert_match(/Issue #999 non trouvée/, out)
  end

  def test_shows_error_issue_iid_and_title
    create_issue(issue_iid: 700, issue_title: 'Broken build', project_path: 'group/proj',
                 status: 'error', error_message: "NoMethodError: undefined method 'foo'",
                 retry_count: 2, branch_name: 'autodev/fix-700')

    out = capture_io { Dashboard.show_errors({ 'database_url' => 'sqlite://:memory:' }) }.first

    assert_match(/#700/, out)
    assert_match(/Broken build/, out)
    assert_match(/NoMethodError/, out)
  end

  def test_shows_error_retry_count_and_branch
    create_issue(issue_iid: 700, issue_title: 'Broken build', project_path: 'group/proj',
                 status: 'error', error_message: 'fail', retry_count: 2, branch_name: 'autodev/fix-700')

    out = capture_io { Dashboard.show_errors({ 'database_url' => 'sqlite://:memory:' }) }.first

    assert_match(/Tentative: 2/, out)
    assert_match(%r{autodev/fix-700}, out)
  end

  def test_shows_blocked_issue
    create_issue(issue_iid: 701, issue_title: 'Blocked thing', project_path: 'group/proj',
                 status: 'blocked', error_message: 'Pipeline infra failure')

    out = capture_io { Dashboard.show_errors({ 'database_url' => 'sqlite://:memory:' }) }.first

    assert_match(/#701/, out)
    assert_match(/blocked/, out)
    refute_match(/Tentative/, out)
  end

  def test_shows_stderr
    create_issue(issue_iid: 702, issue_title: 'With stderr', project_path: 'group/proj',
                 status: 'error', error_message: 'Failed', dc_stderr: "warning: something\nerror line")

    out = capture_io { Dashboard.show_errors({ 'database_url' => 'sqlite://:memory:' }) }.first

    assert_match(/stderr/, out)
    assert_match(/warning: something/, out)
  end

  def test_filters_by_iid
    create_issue(issue_iid: 710, issue_title: 'Error A', project_path: 'group/proj',
                 status: 'error', error_message: 'fail A')
    create_issue(issue_iid: 711, issue_title: 'Error B', project_path: 'group/proj',
                 status: 'error', error_message: 'fail B')

    out = capture_io { Dashboard.show_errors({ 'database_url' => 'sqlite://:memory:', 'errors_iid' => 711 }) }.first

    refute_match(/#710/, out)
    assert_match(/#711/, out)
  end

  def test_shows_post_completion_errors
    create_issue(issue_iid: 720, issue_title: 'PC error', project_path: 'group/proj',
                 status: 'over', post_completion_error: 'deploy script failed')

    out = capture_io { Dashboard.show_errors({ 'database_url' => 'sqlite://:memory:' }) }.first

    assert_match(/#720/, out)
    assert_match(/post_completion/, out)
    assert_match(/deploy script failed/, out)
  end

  def test_shows_mr_info_on_error
    create_issue(issue_iid: 730, issue_title: 'MR error', project_path: 'group/proj',
                 status: 'error', error_message: 'fail', mr_iid: 55, mr_url: 'https://example.com/mr/55')

    out = capture_io { Dashboard.show_errors({ 'database_url' => 'sqlite://:memory:' }) }.first

    assert_match(/!55/, out)
  end
end

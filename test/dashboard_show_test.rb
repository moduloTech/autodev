# frozen_string_literal: true

require_relative 'autodev_test_helper'

# Tests for Dashboard.show and Dashboard.status_label.
class DashboardShowTest < Minitest::Test
  include DatabaseTestHelper
  include StubDatabaseConnect

  def setup
    setup_database
    super
  end

  def test_active_states_return_en_cours
    %w[cloning implementing reviewing checking_pipeline].each do |s|
      assert_equal 'En cours', Dashboard.status_label(s), "Expected 'En cours' for #{s}"
    end
  end

  def test_pending_label
    assert_equal 'En attente', Dashboard.status_label('pending')
  end

  def test_needs_clarification_label
    assert_equal 'En attente de clarification', Dashboard.status_label('needs_clarification')
  end

  def test_done_label
    assert_equal 'Terminée', Dashboard.status_label('done')
  end

  def test_error_label
    assert_equal 'Erreur', Dashboard.status_label('error')
  end

  def test_unknown_status_returns_itself
    assert_equal 'banana', Dashboard.status_label('banana')
  end

  def test_no_issues_message
    out = capture_io { Dashboard.show({ 'database_url' => 'sqlite://:memory:' }) }.first

    assert_match(/Aucune issue active/, out)
  end

  def test_no_issues_with_all_flag
    out = capture_io { Dashboard.show({ 'database_url' => 'sqlite://:memory:', 'status_all' => true }) }.first

    assert_match(/Aucune issue suivie/, out)
  end

  def test_dashboard_shows_pending_issue
    create_issue(issue_iid: 100, issue_title: 'Fix the bug', project_path: 'group/myapp', status: 'pending')

    out = capture_io { Dashboard.show({ 'database_url' => 'sqlite://:memory:' }) }.first

    assert_match(/#100/, out)
    assert_match(/Fix the bug/, out)
    assert_match(/pending/, out)
  end

  def test_dashboard_shows_implementing_issue
    create_issue(issue_iid: 101, issue_title: 'Add feature', project_path: 'group/myapp', status: 'implementing')

    out = capture_io { Dashboard.show({ 'database_url' => 'sqlite://:memory:' }) }.first

    assert_match(/#101/, out)
    assert_match(/implementing/, out)
  end

  def test_dashboard_excludes_done_by_default
    create_issue(issue_iid: 200, issue_title: 'Done issue', project_path: 'group/project', status: 'done')

    out = capture_io { Dashboard.show({ 'database_url' => 'sqlite://:memory:' }) }.first

    refute_match(/#200/, out)
  end

  def test_dashboard_includes_done_with_all_flag
    create_issue(issue_iid: 201, issue_title: 'Done issue', project_path: 'group/project', status: 'done')

    out = capture_io { Dashboard.show({ 'database_url' => 'sqlite://:memory:', 'status_all' => true }) }.first

    assert_match(/#201/, out)
    assert_match(/done/, out)
  end

  def test_dashboard_shows_error_excerpt
    create_issue(issue_iid: 300, issue_title: 'Broken', project_path: 'group/proj',
                 status: 'error', error_message: "RuntimeError: something went wrong\nbacktrace here")

    out = capture_io { Dashboard.show({ 'database_url' => 'sqlite://:memory:' }) }.first

    assert_match(/RuntimeError/, out)
  end

  def test_dashboard_truncates_long_title
    create_issue(issue_iid: 400, issue_title: 'A' * 50, project_path: 'group/proj', status: 'pending')

    out = capture_io { Dashboard.show({ 'database_url' => 'sqlite://:memory:' }) }.first

    assert_match(/A{37}…/, out)
  end

  def test_dashboard_shows_mr_info
    create_issue(issue_iid: 500, issue_title: 'With MR', project_path: 'group/proj',
                 status: 'implementing', mr_iid: 42, mr_url: 'https://gitlab.example.com/mr/42')

    out = capture_io { Dashboard.show({ 'database_url' => 'sqlite://:memory:' }) }.first

    assert_match(/MR !42/, out)
  end

  def test_dashboard_shows_hidden_count
    create_issue(issue_iid: 600, issue_title: 'Completed', project_path: 'group/project', status: 'done')
    create_issue(issue_iid: 601, issue_title: 'Active', status: 'pending')

    out = capture_io { Dashboard.show({ 'database_url' => 'sqlite://:memory:' }) }.first

    assert_match(/terminées masquées/, out)
  end

  def test_status_colors_covers_all_states
    all_states = Dashboard::ACTIVE_STATES + %w[pending answering_question needs_clarification done error]

    all_states.each do |state|
      assert Dashboard::STATUS_COLORS.key?(state), "STATUS_COLORS missing key '#{state}'"
    end
  end

  def test_status_colors_frozen
    assert_predicate Dashboard::STATUS_COLORS, :frozen?
  end
end

# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'web_test_helper'

class WebIssuesFilterTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  include Rack::Test::Methods
  include DatabaseTestHelper
  include WebServerTestSetup

  def test_issues_route_lists_all_statuses
    create_issue(status: 'done', issue_title: 'Done one')
    create_issue(status: 'error', issue_title: 'Error one')
    get '/issues'

    assert_includes last_response.body, 'Done one'
    assert_includes last_response.body, 'Error one'
  end

  def test_keyword_filter_matches_title
    create_issue(issue_title: 'Migration script')
    create_issue(issue_title: 'Refactor controllers')
    get '/issues', { q: 'migration' }

    assert_includes last_response.body, 'Migration script'
    refute_includes last_response.body, 'Refactor controllers'
  end

  def test_keyword_filter_is_case_insensitive
    create_issue(issue_title: 'AbCdEf widget')
    get '/issues', { q: 'abcdef' }

    assert_includes last_response.body, 'AbCdEf widget'
  end

  def test_keyword_filter_escapes_sql_wildcards
    create_issue(issue_title: 'Plain title')
    create_issue(issue_title: 'Title with literal %')
    get '/issues', { q: '%' }

    refute_includes last_response.body, 'Plain title'
    assert_includes last_response.body, 'literal %'
  end

  def test_date_from_filter
    Database.db[:issues].insert(project_path: 'a/b', issue_iid: 1, issue_title: 'Old', status: 'done',
                                created_at: '2026-01-01 00:00:00')
    Database.db[:issues].insert(project_path: 'a/b', issue_iid: 2, issue_title: 'Recent', status: 'done',
                                created_at: '2026-05-06 12:00:00')
    get '/issues', { from: '2026-04-01' }

    assert_includes last_response.body, 'Recent'
    refute_includes last_response.body, '>Old<'
  end

  def test_date_to_filter
    Database.db[:issues].insert(project_path: 'a/b', issue_iid: 3, issue_title: 'Old', status: 'done',
                                created_at: '2026-01-01 00:00:00')
    Database.db[:issues].insert(project_path: 'a/b', issue_iid: 4, issue_title: 'Recent', status: 'done',
                                created_at: '2026-05-06 12:00:00')
    get '/issues', { to: '2026-03-01' }

    assert_includes last_response.body, '>Old<'
    refute_includes last_response.body, 'Recent'
  end

  def test_pagination_per_page_clamped_to_default_when_invalid
    25.times { |i| create_issue(issue_title: "Issue #{i}") }
    get '/issues', { per_page: '999' }

    # 25 issues fit in default 50 → no pager rendered.
    refute_includes last_response.body, 'issues-pager'
  end

  def test_pagination_with_smaller_per_page_creates_pages
    25.times { |i| create_issue(issue_title: "Issue #{i}") }
    get '/issues', { per_page: '20' }

    assert_includes last_response.body, 'Page 1 / 2'
  end

  def test_pagination_second_page_indicates_position
    25.times { |i| create_issue(issue_title: "Issue #{i}") }
    get '/issues', { per_page: '20', page: '2' }

    assert_includes last_response.body, 'Page 2 / 2'
  end

  def test_issues_link_appears_in_nav
    get '/'

    assert_includes last_response.body, 'href="/issues"'
  end

  def test_tab_active_filters_to_active_states_only
    create_issue(status: 'cloning', issue_title: 'WIP')
    create_issue(status: 'done', issue_title: 'Old')
    get '/issues', { tab: 'active' }

    assert_includes last_response.body, 'WIP'
    refute_includes last_response.body, 'Old'
  end

  def test_tab_done_filters_to_done_only
    create_issue(status: 'cloning', issue_title: 'WIP')
    create_issue(status: 'done', issue_title: 'Old')
    get '/issues', { tab: 'done' }

    assert_includes last_response.body, 'Old'
    refute_includes last_response.body, 'WIP'
  end

  def test_tab_errors_filters_to_error_only
    create_issue(status: 'error', issue_title: 'Boom')
    create_issue(status: 'done', issue_title: 'Old')
    get '/issues', { tab: 'errors' }

    assert_includes last_response.body, 'Boom'
    refute_includes last_response.body, 'Old'
  end

  def test_tab_all_default_shows_all
    create_issue(status: 'cloning', issue_title: 'WIP')
    create_issue(status: 'done', issue_title: 'Old')
    get '/issues'

    assert_includes last_response.body, 'WIP'
    assert_includes last_response.body, 'Old'
  end

  def test_invalid_tab_falls_back_to_all
    create_issue(status: 'cloning', issue_title: 'WIP')
    create_issue(status: 'done', issue_title: 'Old')
    get '/issues', { tab: 'klingon' }

    assert_includes last_response.body, 'WIP'
    assert_includes last_response.body, 'Old'
  end

  def test_tab_links_preserve_search_query
    get '/issues', { q: 'whatever', tab: 'active' }
    body = last_response.body

    # Other-tab anchors carry q= forward
    assert_includes body, 'href="/issues?tab=done&q=whatever"'
  end
end

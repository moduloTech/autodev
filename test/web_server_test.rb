# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'web_test_helper'

class WebServerTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  include Rack::Test::Methods
  include DatabaseTestHelper
  include WebServerTestSetup

  def test_root_renders_dashboard
    create_issue(status: 'cloning', issue_title: 'Hello')
    get '/'

    assert_predicate last_response, :ok?
    assert_includes last_response.body, 'Bonjour'
  end

  def test_root_lists_active_issues
    create_issue(status: 'cloning', issue_title: 'Hello')
    get '/'

    assert_includes last_response.body, 'Hello'
  end

  def test_dashboard_groups_by_project
    create_issue(project_path: 'a/b', status: 'cloning')
    create_issue(project_path: 'c/d', status: 'cloning')
    get '/'

    assert_includes last_response.body, 'a/b'
    assert_includes last_response.body, 'c/d'
  end

  def test_errors_route_lists_errored_issues
    create_issue(status: 'error', error_message: 'boom')
    get '/errors'

    assert_predicate last_response, :ok?
    assert_includes last_response.body, 'boom'
  end

  def test_issue_show_renders_metadata
    issue = create_issue(issue_title: 'Test issue', branch_name: 'feat/x')
    get "/issues/#{issue.id}"

    assert_predicate last_response, :ok?
    assert_includes last_response.body, 'Test issue'
    assert_includes last_response.body, 'feat/x'
  end

  def test_issue_show_lists_activity_events
    issue = create_issue
    issue.start_processing!
    get "/issues/#{issue.id}"

    assert_includes last_response.body, 'pending → cloning'
  end

  def test_issue_show_returns_404_when_missing
    get '/issues/999999'

    assert_equal 404, last_response.status
  end

  def test_issue_show_json_returns_payload
    issue = create_issue(issue_title: 'JSON me')
    get "/issues/#{issue.id}.json"
    parsed = JSON.parse(last_response.body)

    assert_equal 'JSON me', parsed['issue_title']
  end

  def test_project_show_renders_issues
    create_issue(project_path: 'group/project', issue_title: 'Within project')
    get '/projects/group__project'

    assert_predicate last_response, :ok?
    assert_includes last_response.body, 'Within project'
  end

  def test_project_show_renders_app_config
    get '/projects/group__project'

    assert_includes last_response.body, 'bin/test'
  end

  def test_dashboard_uses_gitlab_url_from_config
    create_issue(status: 'cloning', issue_iid: 4242)
    issue = Issue.where(issue_iid: 4242).first
    get "/issues/#{issue.id}"

    assert_includes last_response.body, 'https://gitlab.example.com/group/project/-/issues/4242'
  end

  def test_layout_includes_turbo_script
    get '/'

    assert_includes last_response.body, '/assets/turbo.js'
  end

  def test_assets_route_serves_turbo
    get '/assets/turbo.js'

    assert_predicate last_response, :ok?
    assert_includes last_response.content_type, 'javascript'
  end

  def test_list_route_shows_done_issues
    create_issue(status: 'done', issue_title: 'Old finished work', mr_iid: 42)
    get '/list/done'

    assert_predicate last_response, :ok?
    assert_includes last_response.body, 'Old finished work'
  end

  def test_list_route_filters_by_status
    create_issue(status: 'done', issue_title: 'Done one')
    create_issue(status: 'error', issue_title: 'Error one')
    get '/list/done'

    assert_includes last_response.body, 'Done one'
    refute_includes last_response.body, 'Error one'
  end

  def test_dashboard_renders_kpi_grid
    create_issue(status: 'cloning')
    get '/'

    assert_includes last_response.body, 'kpi-grid'
  end

  def test_dashboard_by_project_includes_done_issues
    create_issue(project_path: 'a/b', status: 'done')
    get '/'

    assert_includes last_response.body, 'a/b'
  end

  def test_dashboard_renders_active_requests_section
    create_issue(status: 'cloning', issue_title: 'WIP')
    get '/'

    assert_includes last_response.body, 'Demandes en cours'
  end

  def test_dashboard_marks_unimplemented_features_coming_soon
    get '/'
    body = last_response.body

    # Conversations + Projets sidebar items, search bar, bell, CTA, "Nouvelle
    # demande" topbar button all sit under elements carrying the coming-soon
    # class so they're visually dimmed and unclickable.
    assert_includes body, 'class="coming-soon-badge"'
    # At least one element has the disabled visual treatment.
    assert_operator body.scan('coming-soon').size, :>=, 5, 'expected several coming-soon markers'
  end
end

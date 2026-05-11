# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'web_test_helper'

class WebProjectsIndexTest < Minitest::Test
  include Rack::Test::Methods
  include DatabaseTestHelper
  include WebServerTestSetup

  def test_index_lists_projects_with_db_issues
    create_issue(project_path: 'group/db-project', status: 'cloning')
    get '/projects'

    assert_predicate last_response, :ok?
    assert_includes last_response.body, 'group/db-project'
  end

  def test_index_lists_configured_projects_without_issues
    # WebServerTestSetup configures one project at 'group/project' but no
    # issues exist for it in this test. It should still show up.
    get '/projects'

    assert_includes last_response.body, 'group/project'
  end

  def test_index_renders_topbar_title
    get '/projects'

    assert_includes last_response.body, 'Projets'
  end

  def test_sidebar_projects_item_links_to_index
    get '/'

    # No longer carries the coming-soon class on the Projets item — it now
    # points at /projects and is fully navigable.
    assert_includes last_response.body, 'href="/projects"'
  end

  def test_each_card_links_to_project_show
    create_issue(project_path: 'g/p', status: 'cloning')
    get '/projects'

    assert_includes last_response.body, 'href="/projects/g__p"'
  end

  def test_index_empty_state_when_no_projects
    Web::Server.configure_with({}) # no 'projects' in config
    get '/projects'

    assert_includes last_response.body, 'Aucun projet'
  end
end

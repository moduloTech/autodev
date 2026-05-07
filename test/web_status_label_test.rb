# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'web_test_helper'

class WebStatusLabelTest < Minitest::Test
  include Rack::Test::Methods
  include DatabaseTestHelper

  def app
    Web::Server
  end

  def setup
    setup_database
    Web::Server.configure_with({})
  end

  def test_translates_done_via_cookie_to_english
    issue = create_issue(status: 'done', issue_title: 'Anything')
    set_cookie 'locale=en'
    get "/issues/#{issue.id}"

    assert_includes last_response.body, 'Done'
    refute_includes last_response.body, 'Terminé'
  end

  def test_french_default_renders_done
    issue = create_issue(status: 'done', issue_title: 'Anything')
    get "/issues/#{issue.id}"

    assert_includes last_response.body, 'Terminé'
  end

  def test_cloning_uses_per_state_english_label
    issue = create_issue(status: 'cloning', issue_title: 'Anything')
    set_cookie 'locale=en'
    get "/issues/#{issue.id}"

    assert_includes last_response.body, 'Setting up'
  end

  def test_implementing_uses_per_state_french_label
    issue = create_issue(status: 'implementing', issue_title: 'Anything')
    get "/issues/#{issue.id}"

    assert_includes last_response.body, 'Développement en cours'
  end

  def test_pending_translates
    issue = create_issue(status: 'pending', issue_title: 'Anything')
    set_cookie 'locale=en'
    get "/issues/#{issue.id}"

    assert_includes last_response.body, 'Pending'
  end

  def test_error_translates
    issue = create_issue(status: 'error', issue_title: 'Anything')
    set_cookie 'locale=en'
    get "/issues/#{issue.id}"

    assert_includes last_response.body, 'Failed'
  end
end

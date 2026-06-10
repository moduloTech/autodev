# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# Coverage for the global `authenticate_user!` filter + the public
# escape hatches (Devise's own callbacks, AssetsController). PR3 of
# the users-rollout chantier.
class GatingTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  def test_anonymous_dashboard_redirects_to_sign_in
    get '/'

    assert_response :redirect
  end

  def test_anonymous_projects_index_redirects
    get '/projects'

    assert_response :redirect
  end

  def test_anonymous_issues_show_redirects
    issue = Issue.create!(project_path: 'group/proj', issue_iid: 1, status: 'pending')
    get "/issues/#{issue.id}"

    assert_response :redirect
  end

  def test_assets_controller_skips_authentication_filter
    # Propshaft::Server middleware intercepts `/assets/*` in test env
    # before the route reaches AssetsController, so we can't get a 200
    # back via Rack — but the filter chain on the controller itself is
    # what proves the skip works at the action level (and is what
    # would matter in production where Puma serves /assets/* directly).
    filters = AssetsController._process_action_callbacks.map(&:filter)

    refute_includes filters, :authenticate_user!
  end

  def test_sign_in_page_renders_for_anonymous
    get '/sign_in'

    assert_response :success
  end

  def test_sign_in_page_carries_post_button_to_omniauth
    get '/sign_in'

    assert_includes response.body, 'action="/users/auth/entra_id"'
    assert_includes response.body, 'method="post"'
  end

  def test_anonymous_dashboard_redirect_lands_on_sign_in
    get '/'

    assert_match(%r{/sign_in\z}, response.headers['Location'].to_s)
  end

  def test_logged_in_user_reaches_dashboard
    sign_in User.create!(email: 'user@modulotech.fr', name: 'User', admin: true)
    get '/'

    assert_response :success
  end
end

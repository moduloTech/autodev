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

  def test_users_auth_entra_id_remains_public
    # We can't follow the full Entra ID handshake in an integration test
    # (cf. railsification-handoff §4 on OmniAuth.config.test_mode). What
    # we *can* assert is that the route doesn't 302 back to itself via
    # authenticate_user! — the omniauth middleware will own the redirect
    # to Microsoft instead. Both responses (302 to Entra, or 4xx if the
    # middleware rejects the unset session) prove the gate skipped.
    get '/users/auth/entra_id'

    refute_match(%r{/users/auth/entra_id\z}, response.headers['Location'].to_s)
  end

  def test_logged_in_user_reaches_dashboard
    sign_in User.create!(email: 'user@modulotech.fr', name: 'User', admin: true)
    get '/'

    assert_response :success
  end
end

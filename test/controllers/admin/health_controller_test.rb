# frozen_string_literal: true

require_relative '../../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# /admin/health — admin-gated system health page. Renders the same
# HealthReport as /healthz but inside the dashboard chrome.
module Admin
  class HealthControllerTest < ActionDispatch::IntegrationTest
    include Devise::Test::IntegrationHelpers

    setup do
      @admin = User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)
      @member = User.create!(email: 'member@modulotech.fr', name: 'Member')
    end

    test 'admin sees the health page' do
      sign_in @admin
      get '/admin/health'

      assert_response :ok
      assert_includes response.body, 'État global' # web_admin_health_overall (fr default)
    end

    test 'non-admin is forbidden' do
      sign_in @member
      get '/admin/health'

      assert_response :forbidden
    end

    test 'anonymous is redirected to sign in' do
      get '/admin/health'

      assert_response :redirect
    end
  end
end

# frozen_string_literal: true

require_relative '../../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# Admin guard. PR3 (alpha.7+) put `authenticate_user!` on
# ApplicationController and made `AdminApplicationController` chain
# `require_admin` on top — so anonymous requests now bounce to the
# Entra ID redirect (302), non-admin sessions hit the admin gate
# (403), and admin sessions render the page.
module Admin
  class UsersControllerTest < ActionDispatch::IntegrationTest
    include Devise::Test::IntegrationHelpers

    def test_anonymous_request_redirects_to_sign_in
      get '/admin/users'

      assert_response :redirect
    end

    def test_non_admin_user_returns_forbidden
      sign_in User.create!(email: 'reg@modulotech.fr', name: 'Reg', admin: false)

      get '/admin/users'

      assert_response :forbidden
    end

    def test_admin_user_renders_page
      sign_in User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)

      get '/admin/users'

      assert_response :success
    end

    def test_admin_user_sees_other_users_in_listing
      sign_in User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)
      User.create!(email: 'visible@modulotech.fr', name: 'Visible')

      get '/admin/users'

      assert_includes response.body, 'visible@modulotech.fr'
    end
  end
end

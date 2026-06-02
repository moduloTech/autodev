# frozen_string_literal: true

require_relative '../../rails_helper'

# We deliberately don't drive the full omniauth → callback round-trip from
# an integration test. The OmniAuth `test_mode` plumbing is fragile under
# Devise + omniauth-rails_csrf_protection + our pared-down railtie set, and
# the controller body is small enough (10 lines) that a wiring test gives
# more signal per maintenance dollar than re-staging the OAuth dance:
#
#  1. `Users::OmniauthCallbacksController` resolves and inherits from
#     `Devise::OmniauthCallbacksController` — proves the manual `require`
#     in the controller file works and Devise's engine is registered.
#  2. The `entra_id` and `failure` action methods are defined on the
#     subclass.
#  3. The Rails router has both omniauth routes mapped onto our subclass.
#  4. `User.from_omniauth` is covered exhaustively by user_omniauth_test.rb.
class UsersOmniauthCallbacksControllerWiringTest < ActiveSupport::TestCase
  def test_subclasses_devise_base_controller
    assert_equal Devise::OmniauthCallbacksController,
                 Users::OmniauthCallbacksController.superclass
  end

  def test_defines_entra_id_action
    assert_includes Users::OmniauthCallbacksController.action_methods, 'entra_id'
  end

  def test_defines_failure_action_override
    assert_includes Users::OmniauthCallbacksController.action_methods, 'failure'
  end

  def test_routes_mapped_to_controller
    request_route  = Rails.application.routes.recognize_path('/users/auth/entra_id',          method: :post)
    callback_route = Rails.application.routes.recognize_path('/users/auth/entra_id/callback', method: :post)

    assert_equal 'users/omniauth_callbacks', request_route[:controller]
    assert_equal 'users/omniauth_callbacks', callback_route[:controller]
    assert_equal 'entra_id',                 callback_route[:action]
  end
end

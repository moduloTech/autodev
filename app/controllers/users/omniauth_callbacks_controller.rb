# frozen_string_literal: true

# `config/application.rb` skips `Bundler.require(*Rails.groups)` and the
# Devise engine adds `app/controllers/devise/*` to autoload paths via its
# Railtie — but with our pared-down railtie set the engine isn't fully
# wired. Require the parent controller explicitly so the subclass below
# resolves at boot.
require "#{Gem::Specification.find_by_name('devise').gem_dir}/app/controllers/devise_controller"
require "#{Gem::Specification.find_by_name('devise').gem_dir}/app/controllers/devise/omniauth_callbacks_controller"

module Users
  # Entra ID OAuth2 callback handler (cf. autodev/docs/autospec.md §A).
  #
  # The omniauth middleware (configured in config/initializers/devise.rb)
  # exchanges the authorization code for tokens, builds the auth hash, then
  # POSTs to /users/auth/entra_id/callback which Devise routes here.
  #
  # On success: find-or-create the User via `User.from_omniauth`, sign them
  # in, redirect to the post-auth target. On failure (cancellation, scope
  # rejection, network blip): fall back to the root page with a flash. No
  # automatic re-redirect to the IdP — that would create a loop on tenants
  # that consistently reject our app.
  class OmniauthCallbacksController < Devise::OmniauthCallbacksController
    def entra_id
      user = User.from_omniauth(auth)
      sign_in_and_redirect(user, event: :authentication)
    end

    def failure
      redirect_to root_path, alert: failure_message
    end

    private

    def auth
      request.env['omniauth.auth']
    end
  end
end

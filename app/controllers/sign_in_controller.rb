# frozen_string_literal: true

# Anonymous-accessible sign-in page. Devise's `EntraIdFailureApp`
# (config/initializers/devise.rb) redirects unauthenticated callers
# here; we render a tiny page with a `<form method=post>` button
# that POSTs to `/users/auth/entra_id` carrying a CSRF token, which
# is what `omniauth/rails_csrf_protection` and OmniAuth 2.x's
# default `allowed_request_methods = [:post]` both expect.
#
# Without this page we'd have to allow GET on the omniauth request
# phase (alpha.11) which disables the gem-level CSRF check. The
# POST-via-form approach keeps the canonical Devise + omniauth
# CSRF posture intact (alpha.12 of the users-rollout chantier).
class SignInController < ApplicationController
  include ::Web::Helpers

  skip_before_action :authenticate_user!, raise: false

  def new
    render html: ::Web::Views::SignIn.new(**view_kwargs).call.html_safe, layout: false
  end
end

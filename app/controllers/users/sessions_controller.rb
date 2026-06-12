# frozen_string_literal: true

module Users
  # SSO-only sign-out. The User model only declares `:trackable, :omniauthable`,
  # so `devise_for :users` does not generate the `sessions` resource (which
  # would carry `/users/sign_out`). This controller fills that gap with a
  # single DELETE endpoint that calls Devise's `sign_out` helper and bounces
  # back to the sign-in page.
  #
  # CSRF is skipped on `destroy`. The threat model — a forged sign-out only
  # logs the user out — does not warrant the protection, and it matches the
  # behaviour Devise's `SessionsController` ships with when
  # `:database_authenticatable` is on. Without this skip, the hand-rolled
  # sign-out form (with `_method=delete` overriding the POST) trips the
  # forgery check inconsistently and returns 422.
  class SessionsController < ApplicationController
    skip_before_action :authenticate_user!, raise: false
    skip_forgery_protection only: :destroy

    def destroy
      sign_out(:user) if signed_in?
      redirect_to sign_in_path, status: :see_other
    end
  end
end

# frozen_string_literal: true

# Base controller for every Phlex-rendered page. PR3 of the users-rollout
# chantier (alpha.7+) introduces the global Microsoft 365 SSO gate
# (`authenticate_user!`); Devise's own controllers and AssetsController
# skip the filter explicitly. See `AdminApplicationController` for the
# admin gate chained on top.
class ApplicationController < ActionController::Base
  # PR3 of the users-rollout chantier (cf. docs/users-rollout.md §4). Every
  # request goes through Microsoft 365 SSO from alpha.7 onward — controllers
  # that genuinely need anonymous access (Devise's own sign-in routes; the
  # AssetsController serving static CSS/JS/woff2 to the unauthenticated
  # error page) opt out with `skip_before_action :authenticate_user!`.
  #
  # Devise's own controllers inherit from this class (`Devise.parent_controller`
  # defaults to `ApplicationController`) and explicitly disable the filter
  # via `skip_before_action :authenticate_user!, raise: false` — without that,
  # `/users/auth/entra_id` would redirect back to itself in an infinite loop.
  before_action :authenticate_user!
end

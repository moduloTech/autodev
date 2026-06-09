# frozen_string_literal: true

module Admin
  # GET /admin/users — read-only audit page (cf. docs/users-rollout.md
  # §7 PR2 scope). Guards on `current_user&.admin?` since the global
  # `authenticate_user!` doesn't land until PR3 — the page must not
  # render to anonymous visitors of the dashboard.
  class UsersController < ApplicationController
    include ::Web::Helpers

    before_action :require_admin

    def index
      users = User.order(:email).includes(project_memberships: :project)
      render html: ::Web::Views::Admin::Users.new(
        users: users, locale: web_locale, request_path: request.fullpath
      ).call.html_safe, layout: false
    end

    private

    def require_admin
      return if current_user&.admin?

      head :forbidden
    end
  end
end

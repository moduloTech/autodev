# frozen_string_literal: true

module Admin
  # GET /admin/users — read-only audit page (cf. docs/users-rollout.md
  # §7 PR2 scope). PR3 introduced `AdminApplicationController` which
  # already chains `authenticate_user!` + `require_admin`, so this
  # controller is now a thin shell.
  class UsersController < AdminApplicationController
    include ::Web::Helpers

    def index
      users = User.order(:email).includes(project_memberships: :project)
      render html: ::Web::Views::Admin::Users.new(
        users: users, **view_kwargs
      ).call.html_safe, layout: false
    end
  end
end

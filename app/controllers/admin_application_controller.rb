# frozen_string_literal: true

# Base controller for any route under `/admin/*`. Inherits the global
# `authenticate_user!` from ApplicationController and adds an admin
# gate on top. Used by:
#
# - `Admin::UsersController` (the users × memberships audit page,
#   PR2 of the users-rollout chantier).
# - `MissionControl::Jobs::Engine` (mounted at `/admin/jobs`, wired via
#   `MissionControl::Jobs.base_controller_class` in
#   `config/initializers/mission_control.rb`).
class AdminApplicationController < ApplicationController
  before_action :require_admin

  private

  def require_admin
    return if current_user&.admin?

    head :forbidden
  end
end

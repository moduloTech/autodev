# frozen_string_literal: true

# Manual owner designation on a project's Team tab (Autodev #38). Owner is no
# longer derived from GitLab access level — GitlabMembershipSync only ever
# assigns/reconciles `contributor` rows and treats `owner` rows as immune
# (cf. Autodev::GitlabMembershipSync#reconcile_memberships!). This controller
# is the only path that ever sets or clears the `owner` role.
#
# Patterned after TicketTemplatesController: slug-resolved project, before_action
# gate returning 403/404 with `head`, plain redirect back to the page on
# success.
class ProjectOwnersController < ApplicationController
  include ::Web::Helpers

  before_action :load_project
  before_action :authorize_manager!

  # POST /projects/:slug/owners — promote an existing project member
  # (contributor) to owner. `params[:user_id]` must resolve to a user who
  # already has a membership on this project (owner requires membership);
  # anyone else (not a member at all) is rejected with a flash error instead
  # of creating a fresh membership out of thin air.
  def create
    membership = @project.project_memberships.find_by(user_id: params[:user_id])
    if membership.nil?
      flash[:alert] = t_web(:web_project_owners_not_member_error)
      return redirect_to(team_path)
    end

    membership.update!(role: ::ProjectMembership::ROLE_OWNER)
    ::Audit.record!(resource: @project, action: 'project.owner_granted', actor: current_user,
                    payload: { user_id: membership.user_id })
    redirect_to(team_path)
  end

  # DELETE /projects/:slug/owners/:user_id — demote an owner back to
  # contributor. A no-op (no audit) if the target isn't currently an owner
  # of this project.
  def destroy
    membership = @project.project_memberships.find_by(user_id: params[:user_id], role: ::ProjectMembership::ROLE_OWNER)
    if membership
      membership.update!(role: ::ProjectMembership::ROLE_CONTRIBUTOR)
      ::Audit.record!(resource: @project, action: 'project.owner_revoked', actor: current_user,
                      payload: { user_id: membership.user_id })
    end
    redirect_to(team_path)
  end

  private

  def load_project
    @project = Project.find_by(gitlab_path: project_unslug(params[:slug]))
    head :not_found unless @project
  end

  # admin OR an existing owner of the project (cf. spec's can_manage_owners?).
  def authorize_manager!
    head :forbidden unless can_manage_owners?(@project)
  end

  def can_manage_owners?(project)
    return false unless current_user
    return true if current_user.admin?

    current_user.owner_of?(project)
  end

  def team_path
    "/projects/#{params[:slug]}?tab=team"
  end
end

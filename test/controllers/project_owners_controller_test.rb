# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# Manual owner designation (Autodev #38): a project's Team tab lets an admin
# or an existing owner promote a current member (contributor) to owner, or
# demote an owner back to contributor. Gated by #can_manage_owners? — same
# shape as TicketTemplatesControllerTest's gating checks.
class ProjectOwnersControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @project = Project.create!(gitlab_path: 'group/proj', slug: 'group__proj')
    @admin = User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)
    @project_owner = User.create!(email: 'powner@modulotech.fr', name: 'Owner')
    ProjectMembership.create!(user: @project_owner, project: @project, role: 'owner')
    @contributor = User.create!(email: 'contrib@modulotech.fr', name: 'Contrib')
    ProjectMembership.create!(user: @contributor, project: @project, role: 'contributor')
    @outsider = User.create!(email: 'outsider@modulotech.fr', name: 'Outsider')
  end

  def base = '/projects/group__proj/owners'

  # -- create (promote) --

  def test_admin_can_promote_a_contributor_to_owner
    sign_in @admin
    post base, params: { user_id: @contributor.id }

    assert_redirected_to '/projects/group__proj?tab=team'
    assert_equal 'owner', ProjectMembership.find_by(user: @contributor, project: @project).role
    assert_equal 1, AuditLog.where(action: 'project.owner_granted').count
  end

  def test_project_owner_can_promote_a_contributor_to_owner
    sign_in @project_owner
    post base, params: { user_id: @contributor.id }

    assert_redirected_to '/projects/group__proj?tab=team'
    assert_equal 'owner', ProjectMembership.find_by(user: @contributor, project: @project).role
  end

  def test_contributor_is_forbidden_from_promoting
    sign_in @contributor
    post base, params: { user_id: @contributor.id }

    assert_response :forbidden
  end

  def test_outsider_is_forbidden_from_promoting
    sign_in @outsider
    post base, params: { user_id: @contributor.id }

    assert_response :forbidden
  end

  def test_promoting_a_non_member_is_rejected
    sign_in @admin
    post base, params: { user_id: @outsider.id }

    assert_redirected_to '/projects/group__proj?tab=team'
    assert_nil ProjectMembership.find_by(user: @outsider, project: @project)
    assert_equal 0, AuditLog.where(action: 'project.owner_granted').count
  end

  def test_unknown_project_is_not_found
    sign_in @admin
    post '/projects/no__such/owners', params: { user_id: @contributor.id }

    assert_response :not_found
  end

  # -- destroy (demote) --

  def test_admin_can_demote_an_owner_to_contributor
    sign_in @admin
    delete "#{base}/#{@project_owner.id}"

    assert_redirected_to '/projects/group__proj?tab=team'
    assert_equal 'contributor', ProjectMembership.find_by(user: @project_owner, project: @project).role
    assert_equal 1, AuditLog.where(action: 'project.owner_revoked').count
  end

  def test_project_owner_can_demote_another_owner
    other_owner = User.create!(email: 'powner2@modulotech.fr', name: 'Owner2')
    ProjectMembership.create!(user: other_owner, project: @project, role: 'owner')
    sign_in @project_owner
    delete "#{base}/#{other_owner.id}"

    assert_redirected_to '/projects/group__proj?tab=team'
    assert_equal 'contributor', ProjectMembership.find_by(user: other_owner, project: @project).role
  end

  def test_contributor_is_forbidden_from_demoting
    sign_in @contributor
    delete "#{base}/#{@project_owner.id}"

    assert_response :forbidden
  end

  def test_outsider_is_forbidden_from_demoting
    sign_in @outsider
    delete "#{base}/#{@project_owner.id}"

    assert_response :forbidden
  end
end

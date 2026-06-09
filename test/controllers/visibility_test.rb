# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# Hybrid visibility (PR3 of the users-rollout chantier): admins see
# every project / issue, non-admins see only the rows scoped to their
# `project_memberships`.
class VisibilityTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @mine = Project.create!(gitlab_path: 'group/mine', slug: 'group__mine')
    @other = Project.create!(gitlab_path: 'group/other', slug: 'group__other')
    Issue.create!(project_path: 'group/mine',  issue_iid: 1, status: 'pending')
    Issue.create!(project_path: 'group/other', issue_iid: 2, status: 'pending')

    @admin = User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)
    @member = User.create!(email: 'member@modulotech.fr', name: 'Member')
    ProjectMembership.create!(user: @member, project: @mine, role: 'contributor')
  end

  def test_admin_sees_all_issues_on_dashboard
    sign_in @admin
    get '/'

    assert_includes response.body, 'group/mine'
    assert_includes response.body, 'group/other'
  end

  def test_member_only_sees_visible_project
    sign_in @member
    get '/'

    assert_includes     response.body, 'group/mine'
    refute_includes     response.body, 'group/other'
  end

  def test_member_sees_only_visible_projects_on_projects_index
    sign_in @member
    get '/projects'

    assert_includes response.body, 'group/mine'
    refute_includes response.body, 'group/other'
  end

  def test_member_gets_403_on_invisible_project_slug
    sign_in @member
    get '/projects/group__other'

    assert_response :forbidden
  end

  def test_admin_can_open_any_project_slug
    sign_in @admin
    get '/projects/group__other'

    assert_response :success
  end
end

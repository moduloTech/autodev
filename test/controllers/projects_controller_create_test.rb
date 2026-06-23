# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# Integration test for ProjectsController#new / #create — admin-only project
# creation in the DB (task #9 phase 4, the replacement for adding a `projects:`
# entry to config.yml). gitlab_path drives the derived slug/name; the config
# columns go through the same field-by-field normalizer as #update.
class ProjectsControllerCreateTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers
  include ActiveJob::TestHelper

  setup do
    @existing = Project.create!(gitlab_path: 'group/existing', slug: 'group__existing')
    @admin = User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)
    @member = User.create!(email: 'member@modulotech.fr', name: 'Member')
    ProjectMembership.create!(user: @member, project: @existing, role: 'contributor')
  end

  # -- gating --

  def test_admin_can_open_new_form
    sign_in @admin
    get '/projects/new'

    assert_response :success
    assert_match 'gitlab_path', response.body
  end

  def test_non_admin_cannot_open_new_form
    sign_in @member
    get '/projects/new'

    assert_response :forbidden
  end

  def test_non_admin_cannot_create
    sign_in @member
    assert_no_difference -> { Project.count } do
      post '/projects', params: { gitlab_path: 'group/sneaky' }
    end

    assert_response :forbidden
  end

  # -- create --

  def test_admin_creates_project_with_derived_slug_and_name
    sign_in @admin
    post '/projects', params: { gitlab_path: 'group/sub/created', target_branch: 'main' }
    project = Project.find_by(gitlab_path: 'group/sub/created')

    assert_equal 'group__sub__created', project.slug
    assert_equal 'created', project.name
    assert_equal 'main', project.target_branch
  end

  def test_create_enqueues_membership_sync
    sign_in @admin
    assert_enqueued_with(job: SyncGitlabMembershipsJob) do
      post '/projects', params: { gitlab_path: 'group/synced' }
    end
  end

  def test_invalid_create_re_renders_422_without_persisting
    sign_in @admin
    assert_no_difference -> { Project.count } do
      post '/projects', params: { gitlab_path: '' }
    end

    assert_response :unprocessable_entity
  end
end

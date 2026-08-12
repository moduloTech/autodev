# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# Integration test for ProjectsController#edit / #update — the per-project
# config edit form (task #9 phase 3). Gated on project membership/admin like
# IssuesController#close; #update builds attributes field-by-field (blank →
# nil, integer parse, boolean tri-state, newline → array) and the model's
# phase-1 validations reject a bad edit (re-render 422, nothing saved).
class ProjectsControllerEditTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @project = Project.create!(gitlab_path: 'group/proj', slug: 'group__proj')
    @admin = User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)
    @member = User.create!(email: 'member@modulotech.fr', name: 'Member')
    ProjectMembership.create!(user: @member, project: @project, role: 'contributor')
    @outsider = User.create!(email: 'outsider@modulotech.fr', name: 'Outsider')
  end

  # -- GET /edit gating --

  def test_admin_can_open_edit_form
    sign_in @admin
    get '/projects/group__proj/edit'

    assert_response :success
    assert_match 'target_branch', response.body
  end

  def test_contributor_can_open_edit_form
    sign_in @member
    get '/projects/group__proj/edit'

    assert_response :success
  end

  def test_edit_form_shows_default_value_hints_and_help_panel
    sign_in @member
    get '/projects/group__proj/edit'

    assert_match 'Défaut : 1800', response.body # dc_timeout baked default
    assert_match 'Aide à la configuration', response.body # right-hand help panel
  end

  def test_outsider_is_forbidden
    sign_in @outsider
    get '/projects/group__proj/edit'

    assert_response :forbidden
  end

  # -- ticket-templates entry point kept in the config editor (task #14) --

  def test_edit_page_keeps_the_ticket_templates_link
    sign_in @member
    get '/projects/group__proj/edit'

    assert_match %r{href="/projects/group__proj/ticket_templates"}, response.body
  end

  def test_unknown_project_is_not_found
    sign_in @admin
    get '/projects/no__such/edit'

    assert_response :not_found
  end

  # -- PATCH /update --

  def test_update_persists_scalar_fields
    sign_in @member
    patch '/projects/group__proj', params: { target_branch: 'develop', dc_timeout: '900' }
    @project.reload

    assert_response :redirect
    assert_equal 'develop', @project.target_branch
    assert_equal 900, @project.dc_timeout
  end

  def test_update_persists_list_field_with_complete_label_workflow
    sign_in @member
    patch '/projects/group__proj',
          params: { labels_todo: "todo\nbug", label_doing: 'doing', label_done: 'done' }
    @project.reload

    assert_equal %w[todo bug], @project.labels_todo
    assert_equal 'doing', @project.label_doing
  end

  def test_blank_fields_clear_to_nil
    @project.update!(target_branch: 'main')
    sign_in @member
    patch '/projects/group__proj', params: { target_branch: '' }

    assert_nil @project.reload.target_branch
  end

  def test_boolean_tri_state
    sign_in @member

    patch '/projects/group__proj', params: { parallel_agents: 'true' }

    assert @project.reload.parallel_agents

    patch '/projects/group__proj', params: { parallel_agents: 'false' }

    refute @project.reload.parallel_agents

    patch '/projects/group__proj', params: { parallel_agents: '' }

    assert_nil @project.reload.parallel_agents
  end

  def test_invalid_edit_re_renders_422_without_saving
    @project.update!(dc_timeout: 600)
    sign_in @member
    patch '/projects/group__proj', params: { dc_timeout: '0' }

    assert_response :unprocessable_entity
    assert_equal 600, @project.reload.dc_timeout
  end

  def test_outsider_cannot_update
    sign_in @outsider
    patch '/projects/group__proj', params: { target_branch: 'hijacked' }

    assert_response :forbidden
    assert_nil @project.reload.target_branch
  end

  # The numeric-bounds behaviour of the same form (Autodev #58) lives in
  # test/controllers/projects_controller_numeric_bounds_test.rb.
end

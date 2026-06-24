# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# CRUD + gating for per-project ticket templates (task #14). Gated exactly
# like the per-project config edit: admin or a project collaborator may
# manage; an outsider is forbidden; a missing project row is a 404.
class TicketTemplatesControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @project = Project.create!(gitlab_path: 'group/proj', slug: 'group__proj')
    @admin = User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)
    @member = User.create!(email: 'member@modulotech.fr', name: 'Member')
    ProjectMembership.create!(user: @member, project: @project, role: 'contributor')
    @outsider = User.create!(email: 'outsider@modulotech.fr', name: 'Outsider')
  end

  def base = '/projects/group__proj/ticket_templates'

  # -- index / new gating --

  def test_admin_can_list_templates
    sign_in @admin
    get base

    assert_response :success
  end

  def test_contributor_can_open_new_form
    sign_in @member
    get "#{base}/new"

    assert_response :success
    assert_match 'name', response.body
  end

  def test_outsider_is_forbidden
    sign_in @outsider
    get base

    assert_response :forbidden
  end

  def test_unknown_project_is_not_found
    sign_in @admin
    get '/projects/no__such/ticket_templates'

    assert_response :not_found
  end

  # -- create --

  def test_create_persists_and_derives_slug # rubocop:disable Minitest/MultipleAssertions
    sign_in @member
    assert_difference '@project.ticket_templates.count', 1 do
      post base, params: { name: 'Évolution', body: "## Localisation\n## Contexte" }
    end
    tpl = @project.ticket_templates.order(:id).last

    assert_redirected_to base
    assert_equal 'evolution', tpl.slug
    assert_match(/## Localisation/, tpl.body)
  end

  def test_create_invalid_re_renders_unprocessable
    sign_in @member
    assert_no_difference '@project.ticket_templates.count' do
      post base, params: { name: '', body: '' }
    end

    assert_response :unprocessable_entity
  end

  # -- edit / update / destroy --

  def test_update_persists_changes
    tpl = @project.ticket_templates.create!(name: 'Bug', slug: 'bug', body: '## x')
    sign_in @member
    patch "#{base}/#{tpl.id}", params: { name: 'Bug report', template_slug: 'bug', body: '## Steps' }

    assert_redirected_to base
    assert_equal ['Bug report', '## Steps'], [tpl.reload.name, tpl.body]
  end

  def test_update_unknown_template_is_not_found
    sign_in @member
    patch "#{base}/999999", params: { name: 'X', body: 'y' }

    assert_response :not_found
  end

  def test_destroy_removes_the_template
    tpl = @project.ticket_templates.create!(name: 'Bug', slug: 'bug', body: '## x')
    sign_in @member
    assert_difference '@project.ticket_templates.count', -1 do
      delete "#{base}/#{tpl.id}"
    end

    assert_redirected_to base
  end

  def test_outsider_cannot_create
    sign_in @outsider
    post base, params: { name: 'X', body: 'y' }

    assert_response :forbidden
  end
end

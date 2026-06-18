# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# Integration test for IssuesController#close — manual close gated on project
# membership (the issue lands in the "Clôs" tab). Admins and project
# collaborators can close; an outsider can't even see the issue (find_issue is
# visibility-scoped) so they get a 404.
class IssuesControllerCloseTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @project = Project.create!(gitlab_path: 'group/proj', slug: 'group__proj')
    @admin = User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)
    @member = User.create!(email: 'member@modulotech.fr', name: 'Member')
    ProjectMembership.create!(user: @member, project: @project, role: 'contributor')
    @outsider = User.create!(email: 'outsider@modulotech.fr', name: 'Outsider')
    @issue = Issue.create!(project_path: 'group/proj', issue_iid: 600, status: 'implementing')
  end

  def test_contributor_can_close
    sign_in @member
    post "/issues/#{@issue.id}/close"

    assert_equal 'closed', @issue.reload.status
  end

  def test_admin_can_close
    sign_in @admin
    post "/issues/#{@issue.id}/close"

    assert_equal 'closed', @issue.reload.status
  end

  def test_outsider_cannot_see_or_close
    sign_in @outsider
    post "/issues/#{@issue.id}/close"

    assert_response :not_found
    assert_equal 'implementing', @issue.reload.status
  end

  def test_close_clears_needs_attention
    @issue.update!(status: 'done', needs_attention: true, attention_reason: 'stagnation_pipeline')
    sign_in @member
    post "/issues/#{@issue.id}/close"
    @issue.reload

    assert_equal 'closed', @issue.status
    refute @issue.needs_attention
    assert_nil @issue.attention_reason
  end

  def test_close_writes_a_manual_audit_log
    sign_in @member
    post "/issues/#{@issue.id}/close"
    log = AuditLog.where(action: 'issue.transition_manual', resource_id: @issue.id).last

    assert_not_nil log
    assert_equal @member.id, log.actor_id
    assert_equal 'close', log.payload['event']
  end
end

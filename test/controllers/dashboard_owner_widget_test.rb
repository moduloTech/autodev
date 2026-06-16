# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# Step 11c — the AutoSpec "drafts to vote on" widget on the dashboard.
# Surfaces only the rows the signed-in owner can act on: pending_approval
# drafts on a project they own, where they haven't voted at the current
# iteration. Hidden entirely for users who are owner of zero projects.
class DashboardOwnerWidgetTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @owner    = User.create!(email: 'owner@modulotech.fr', name: 'Owner')
    @author   = User.create!(email: 'author@modulotech.fr', name: 'Author')
    @stranger = User.create!(email: 'stranger@modulotech.fr', name: 'Stranger')
    @project  = Project.create!(gitlab_path: 'group/proj', slug: 'group__proj')
    ProjectMembership.create!(user: @owner,  project: @project, role: 'owner')
    ProjectMembership.create!(user: @author, project: @project, role: 'contributor')
    Autospec::GitlabSubmitter.disabled = true
  end

  teardown do
    Autospec::GitlabSubmitter.disabled = false
  end

  def submitted_draft(title: 'Refactor login')
    draft = AutospecDraft.create!(user: @author, project: @project,
                                  title: title, destination: 'human')
    draft.submit_for_approval!
    draft
  end

  def test_widget_lists_pending_drafts_on_owned_projects
    submitted_draft(title: 'Refactor login')
    sign_in @owner
    get '/'

    assert_includes response.body, 'Brouillons à valider'
    assert_includes response.body, 'Refactor login'
  end

  def test_widget_hidden_for_non_owner
    submitted_draft
    sign_in @stranger
    get '/'

    refute_includes response.body, 'Brouillons à valider'
  end

  def test_widget_filters_out_drafts_already_voted_at_current_iteration
    draft = submitted_draft(title: 'Already voted')
    Autospec::ApprovalRecorder.new(draft, @owner).record_approval!
    # @owner is the only owner, so the draft just finalised — make sure
    # it doesn't appear in the widget any more (it's no longer pending).
    sign_in @owner
    get '/'

    refute_includes response.body, 'Already voted'
  end

  def test_widget_skips_drafts_on_unowned_projects
    other_project = Project.create!(gitlab_path: 'other/proj', slug: 'other__proj')
    ProjectMembership.create!(user: @author, project: other_project, role: 'contributor')
    draft = AutospecDraft.create!(user: @author, project: other_project,
                                  title: 'On other project', destination: 'human')
    draft.submit_for_approval!
    sign_in @owner
    get '/'

    refute_includes response.body, 'On other project'
  end
end

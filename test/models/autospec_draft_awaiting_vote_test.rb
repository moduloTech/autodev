# frozen_string_literal: true

require_relative '../rails_helper'

# AutospecDraft.awaiting_vote_of — the owner-vote set shared by the dashboard
# widget, the /autospec_drafts "À valider" tab, and the sidebar badge:
# pending_approval drafts on a project the user owns, minus those the user has
# already voted on at the draft's current iteration.
class AutospecDraftAwaitingVoteTest < ActiveSupport::TestCase
  setup do
    @owner   = User.create!(email: 'owner@modulotech.fr', name: 'Owner')
    @author  = User.create!(email: 'author@modulotech.fr', name: 'Author')
    @project = Project.create!(gitlab_path: 'group/proj', slug: 'group__proj')
    ProjectMembership.create!(user: @owner,  project: @project, role: 'owner')
    ProjectMembership.create!(user: @author, project: @project, role: 'contributor')
    Autospec::GitlabSubmitter.disabled = true
  end

  teardown { Autospec::GitlabSubmitter.disabled = false }

  def submitted_draft(title:, user: @author, project: @project)
    draft = AutospecDraft.create!(user: user, project: project, title: title, destination: 'human')
    draft.submit_for_approval!
    draft
  end

  def test_nil_user_returns_empty
    submitted_draft(title: 'Whatever')

    assert_empty AutospecDraft.awaiting_vote_of(nil)
  end

  def test_lists_pending_drafts_on_owned_projects
    submitted_draft(title: 'Needs my vote')

    titles = AutospecDraft.awaiting_vote_of(@owner).map(&:title)

    assert_includes titles, 'Needs my vote'
  end

  def test_excludes_drafts_still_drafting
    AutospecDraft.create!(user: @author, project: @project, title: 'Still editing')

    assert_empty AutospecDraft.awaiting_vote_of(@owner)
  end

  def test_excludes_drafts_on_unowned_projects
    other = Project.create!(gitlab_path: 'other/proj', slug: 'other__proj')
    submitted_draft(title: 'Elsewhere', project: other)

    assert_empty AutospecDraft.awaiting_vote_of(@owner)
  end

  def test_excludes_drafts_already_voted_at_current_iteration
    draft = submitted_draft(title: 'Voted')
    # Record the owner's approval at the current iteration; with a second owner
    # the draft stays pending_approval but should drop out of *my* vote set.
    second_owner = User.create!(email: 'owner2@modulotech.fr', name: 'Owner2')
    ProjectMembership.create!(user: second_owner, project: @project, role: 'owner')
    Autospec::ApprovalRecorder.new(draft, @owner).record_approval!

    refute_includes AutospecDraft.awaiting_vote_of(@owner).map(&:id), draft.id
    # the other owner still owes a vote
    assert_includes AutospecDraft.awaiting_vote_of(second_owner).map(&:id), draft.id
  end
end

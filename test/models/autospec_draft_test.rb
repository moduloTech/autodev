# frozen_string_literal: true

require_relative '../rails_helper'

class AutospecDraftTest < ActiveSupport::TestCase
  setup do
    @author  = User.create!(email: 'csm@modulotech.fr', name: 'CSM')
    @project = Project.create!(gitlab_path: 'g/p', slug: 'g__p')
  end

  def test_user_required
    refute_predicate AutospecDraft.new(project: @project), :valid?
  end

  def test_project_required
    refute_predicate AutospecDraft.new(user: @author), :valid?
  end

  def test_destination_inclusion
    draft = AutospecDraft.new(user: @author, project: @project, destination: 'autopilot')

    refute_predicate draft, :valid?
    assert_includes draft.errors[:destination], 'is not included in the list'
  end

  def test_destination_nil_is_valid_while_drafting
    draft = AutospecDraft.new(user: @author, project: @project, destination: nil)

    assert_predicate draft, :valid?
  end

  def test_destination_human_accepted
    assert_predicate AutospecDraft.new(user: @author, project: @project, destination: 'human'), :valid?
  end

  def test_destination_autodev_accepted
    assert_predicate AutospecDraft.new(user: @author, project: @project, destination: 'autodev'), :valid?
  end

  def test_meta_chips_round_trips_as_hash
    AutospecDraft.create!(
      user: @author, project: @project,
      meta_chips: { 'type' => 'bug', 'tags' => %w[ux mobile] }
    )

    reloaded = AutospecDraft.last

    assert_equal({ 'type' => 'bug', 'tags' => %w[ux mobile] }, reloaded.meta_chips)
  end

  def test_default_meta_chips_is_empty_hash
    draft = AutospecDraft.create!(user: @author, project: @project)

    assert_equal({}, draft.meta_chips)
  end

  def test_author_returns_user
    draft = AutospecDraft.create!(user: @author, project: @project)

    assert_equal @author, draft.author
  end

  def test_has_many_messages
    draft = AutospecDraft.create!(user: @author, project: @project)

    assert_empty draft.autospec_messages
  end

  def test_has_many_attachments
    draft = AutospecDraft.create!(user: @author, project: @project)

    assert_empty draft.autospec_attachments
  end

  def test_has_many_approvals
    draft = AutospecDraft.create!(user: @author, project: @project)

    assert_empty draft.autospec_approvals
  end

  def test_destroying_draft_cascades_to_messages
    draft = AutospecDraft.create!(user: @author, project: @project)
    AutospecMessage.create!(autospec_draft: draft, role: 'user', content: 'hi')

    assert_difference 'AutospecMessage.count', -1 do
      draft.destroy
    end
  end

  def test_destroying_draft_cascades_to_approvals
    draft = AutospecDraft.create!(user: @author, project: @project)
    draft.submit_for_approval!
    AutospecApproval.create!(autospec_draft: draft, user: @author,
                             iteration: draft.current_iteration, action: 'approved')

    assert_difference 'AutospecApproval.count', -1 do
      draft.destroy
    end
  end
end

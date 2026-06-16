# frozen_string_literal: true

require_relative '../../rails_helper'

module Autospec
  class ApprovalRecorderTest < ActiveSupport::TestCase
    setup do
      @author  = User.create!(email: 'author@modulotech.fr', name: 'Author')
      @owner_a = User.create!(email: 'owner_a@modulotech.fr', name: 'Owner A')
      @owner_b = User.create!(email: 'owner_b@modulotech.fr', name: 'Owner B')
      @member  = User.create!(email: 'member@modulotech.fr', name: 'Member')
      @project = Project.create!(gitlab_path: 'g/p', slug: 'g__p')
      ProjectMembership.create!(user: @owner_a, project: @project, role: 'owner')
      ProjectMembership.create!(user: @owner_b, project: @project, role: 'owner')
      ProjectMembership.create!(user: @member,  project: @project, role: 'contributor')

      @draft = AutospecDraft.create!(user: @author, project: @project,
                                     title: 'X', destination: 'human')
      @draft.submit_for_approval! # → pending_approval, current_iteration = 1

      # Quorum-met paths call GitlabSubmitter, which would otherwise
      # try to reach the real GitLab API. Disable the side effect for
      # this whole suite — GitlabSubmitter has its own dedicated test.
      GitlabSubmitter.disabled = true
    end

    teardown do
      GitlabSubmitter.disabled = false
    end

    # --- guards -----------------------------------------------------

    def test_raises_when_user_is_not_an_owner
      assert_raises(ApprovalRecorder::NotAnOwner) do
        ApprovalRecorder.new(@draft, @member).record_approval!
      end
    end

    def test_raises_when_draft_not_pending_approval
      @draft.retract!
      assert_raises(ApprovalRecorder::DraftNotPending) do
        ApprovalRecorder.new(@draft, @owner_a).record_approval!
      end
    end

    def test_raises_when_user_already_voted_at_current_iteration
      ApprovalRecorder.new(@draft, @owner_a).record_approval!
      assert_raises(ApprovalRecorder::AlreadyVoted) do
        ApprovalRecorder.new(@draft, @owner_a).record_approval!
      end
    end

    # --- approval flow ----------------------------------------------

    def test_single_owner_approval_does_not_finalize_when_multiple_owners
      ApprovalRecorder.new(@draft, @owner_a).record_approval!

      assert_equal 'pending_approval', @draft.reload.status
    end

    def test_all_owners_approved_finalizes
      ApprovalRecorder.new(@draft, @owner_a).record_approval!
      ApprovalRecorder.new(@draft, @owner_b).record_approval!

      assert_equal 'submitted', @draft.reload.status
    end

    def test_approval_persists_row_with_iteration_and_action
      ApprovalRecorder.new(@draft, @owner_a).record_approval!
      row = @draft.autospec_approvals.last

      assert_equal 'approved', row.action
      assert_equal 1, row.iteration
      assert_equal @owner_a, row.user
    end

    # --- rejection flow ---------------------------------------------

    def test_rejection_marks_draft_rejected
      ApprovalRecorder.new(@draft, @owner_a).record_rejection!('not specific enough')

      assert_equal 'rejected', @draft.reload.status
    end

    def test_rejection_requires_a_reason
      assert_raises(ActiveRecord::RecordInvalid) do
        ApprovalRecorder.new(@draft, @owner_a).record_rejection!('')
      end
      assert_equal 'pending_approval', @draft.reload.status
    end

    # --- iteration semantics ----------------------------------------

    # After a rejection + resume_from_rejection + re-submit, the
    # iteration is bumped; previous-iteration approvals don't count
    # toward the new round's quorum.
    def test_previous_iteration_approvals_dont_count_toward_quorum
      ApprovalRecorder.new(@draft, @owner_a).record_approval!
      # Reject from owner_b → draft goes to rejected
      ApprovalRecorder.new(@draft, @owner_b).record_rejection!('redo')
      @draft.resume_from_rejection!
      @draft.submit_for_approval! # iteration → 2

      assert_equal 2, @draft.current_iteration

      # owner_a's iteration-1 approval shouldn't count any more.
      ApprovalRecorder.new(@draft, @owner_a).record_approval!

      assert_equal 'pending_approval', @draft.reload.status
    end
  end
end

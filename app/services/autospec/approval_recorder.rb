# frozen_string_literal: true

module Autospec
  # Records one owner's vote (approval or rejection) on a draft at its
  # current iteration. Atomic: the AutospecApproval row + the AASM
  # transition on the draft (if any) succeed together or roll back
  # together.
  #
  # Decisions (autospec.md §E, §J):
  #   - First rejection at the current iteration → `mark_rejected!` on
  #     the draft. Other owners' approvals/rejections at the same
  #     iteration are still recorded (audit trail) but won't change the
  #     state further.
  #   - All owners approved → `finalize!` on the draft. Triggers the
  #     GitlabSubmitter via the AASM after-transition hook (step 11d).
  #   - Otherwise stays in `pending_approval` waiting for more votes.
  #
  # The iteration semantics matter: after a `retract` or `mark_rejected`,
  # the draft re-enters `drafting`; a subsequent `submit_for_approval`
  # bumps `current_iteration`. Old approvals stay in the DB tagged with
  # the older iteration (audit trail) but the quorum check only looks
  # at rows matching the current iteration.
  class ApprovalRecorder
    class NotAnOwner < StandardError; end
    class AlreadyVoted < StandardError; end
    class DraftNotPending < StandardError; end

    def initialize(draft, user)
      @draft = draft
      @user  = user
    end

    def record_approval!
      record!(action: AutospecApproval::ACTION_APPROVED, reason: nil)
    end

    def record_rejection!(reason)
      record!(action: AutospecApproval::ACTION_REJECTED, reason: reason)
    end

    private

    def record!(action:, reason:)
      validate!

      ActiveRecord::Base.transaction do
        @draft.autospec_approvals.create!(
          user: @user, iteration: @draft.current_iteration,
          action: action, reason: reason
        )
        apply_quorum_decision!(action)
      end
    end

    def validate!
      raise DraftNotPending, "draft ##{@draft.id} not in pending_approval" unless @draft.pending_approval?
      unless @user.owner_of?(@draft.project)
        raise NotAnOwner,
              "user ##{@user.id} not owner of project ##{@draft.project_id}"
      end
      return unless already_voted?

      raise AlreadyVoted,
            "user ##{@user.id} already voted at iteration #{@draft.current_iteration}"
    end

    def already_voted?
      @draft.autospec_approvals.exists?(user: @user, iteration: @draft.current_iteration)
    end

    def apply_quorum_decision!(action)
      if action == AutospecApproval::ACTION_REJECTED
        @draft.mark_rejected!
      elsif all_owners_approved?
        # Submit to GitLab BEFORE the AASM transition so a failure
        # rolls back the surrounding transaction (the approval row +
        # the finalize) and the operator can retry by clicking
        # Approuver again. See GitlabSubmitter for the failure-mode
        # caveat about orphan GitLab uploads on mid-flight errors.
        GitlabSubmitter.new(@draft).submit!
        @draft.finalize!
      end
    end

    # Quorum = every owner of the project has an `approved` row at the
    # current iteration. We also require ≥1 owner so a zero-owner project
    # can't auto-finalize on… nothing. (If a project somehow ends up with
    # no owners, the draft stays in pending_approval until someone fixes
    # the membership table — failing safe.)
    def all_owners_approved?
      owner_ids = ProjectMembership
                  .where(project_id: @draft.project_id, role: ProjectMembership::ROLE_OWNER)
                  .pluck(:user_id)
      return false if owner_ids.empty?

      voted_ids = @draft.autospec_approvals
                        .where(iteration: @draft.current_iteration,
                               action: AutospecApproval::ACTION_APPROVED)
                        .pluck(:user_id)
      (owner_ids - voted_ids).empty?
    end
  end
end

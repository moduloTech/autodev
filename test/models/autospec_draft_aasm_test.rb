# frozen_string_literal: true

require_relative '../rails_helper'

# AASM state machine for AutospecDraft (cf. autodev/docs/autospec.md §E).
# Split from `autospec_draft_test.rb` so each file stays under the
# class-length budget — same pattern as `issue_audit_log_test.rb`
# carving the Issue AASM audit fan-out into its own file.
class AutospecDraftAasmTest < ActiveSupport::TestCase
  setup do
    @author  = User.create!(email: 'csm@modulotech.fr', name: 'CSM')
    @project = Project.create!(gitlab_path: 'g/p', slug: 'g__p')
    @draft   = AutospecDraft.create!(user: @author, project: @project)
  end

  def test_initial_status_is_drafting
    assert_equal 'drafting', @draft.status
    assert_predicate @draft, :drafting?
  end

  def test_initial_iteration_is_zero
    assert_equal 0, @draft.current_iteration
  end

  def test_submit_for_approval_transitions_to_pending
    @draft.submit_for_approval!

    assert_predicate @draft, :pending_approval?
  end

  def test_submit_for_approval_increments_iteration
    @draft.submit_for_approval!

    assert_equal 1, @draft.current_iteration
  end

  def test_retract_returns_to_drafting
    @draft.submit_for_approval!
    @draft.retract!

    assert_predicate @draft, :drafting?
  end

  def test_retract_keeps_iteration
    @draft.submit_for_approval!
    @draft.retract!

    assert_equal 1, @draft.current_iteration
  end

  def test_resubmit_after_retract_bumps_iteration_again
    @draft.submit_for_approval!  # 0 → 1
    @draft.retract!
    @draft.submit_for_approval!  # 1 → 2

    assert_equal 2, @draft.current_iteration
  end

  def test_mark_rejected_from_pending_approval
    @draft.submit_for_approval!
    @draft.mark_rejected!

    assert_predicate @draft, :rejected?
  end

  def test_resume_from_rejection_returns_to_drafting
    @draft.submit_for_approval!
    @draft.mark_rejected!
    @draft.resume_from_rejection!

    assert_predicate @draft, :drafting?
  end

  def test_resume_from_rejection_keeps_iteration
    @draft.submit_for_approval!
    @draft.mark_rejected!
    @draft.resume_from_rejection!

    assert_equal 1, @draft.current_iteration
  end

  def test_finalize_from_pending_approval
    @draft.submit_for_approval!
    @draft.finalize!

    assert_predicate @draft, :submitted?
  end

  def test_invalid_transitions_return_false_without_raising
    # finalize only fires from :pending_approval; whiny_transitions: false
    # means we get a false return instead of an AASM::InvalidTransition.
    refute @draft.finalize
    assert_predicate @draft, :drafting?
  end
end

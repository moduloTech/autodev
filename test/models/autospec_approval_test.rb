# frozen_string_literal: true

require_relative '../rails_helper'

class AutospecApprovalTest < ActiveSupport::TestCase
  setup do
    @author  = User.create!(email: 'csm@modulotech.fr', name: 'CSM')
    @owner   = User.create!(email: 'owner@modulotech.fr', name: 'Owner')
    @project = Project.create!(gitlab_path: 'g/p', slug: 'g__p')
    @draft   = AutospecDraft.create!(user: @author, project: @project)
    @draft.submit_for_approval!
  end

  def test_action_must_be_approved_or_rejected
    approval = AutospecApproval.new(
      autospec_draft: @draft, user: @owner,
      iteration: 1, action: 'maybe'
    )

    refute_predicate approval, :valid?
    assert_includes approval.errors[:action], 'is not included in the list'
  end

  def test_reason_required_when_rejected
    approval = AutospecApproval.new(
      autospec_draft: @draft, user: @owner,
      iteration: 1, action: 'rejected', reason: nil
    )

    refute_predicate approval, :valid?
    assert_includes approval.errors[:reason], "can't be blank"
  end

  def test_reason_optional_when_approved
    approval = AutospecApproval.new(
      autospec_draft: @draft, user: @owner,
      iteration: 1, action: 'approved'
    )

    assert_predicate approval, :valid?
  end

  def test_iteration_must_be_positive_integer
    approval = AutospecApproval.new(
      autospec_draft: @draft, user: @owner,
      iteration: 0, action: 'approved'
    )

    refute_predicate approval, :valid?
  end

  def test_one_vote_per_owner_per_iteration_model_level
    AutospecApproval.create!(
      autospec_draft: @draft, user: @owner,
      iteration: 1, action: 'approved'
    )
    duplicate = AutospecApproval.new(
      autospec_draft: @draft, user: @owner,
      iteration: 1, action: 'rejected', reason: 'changed my mind'
    )

    refute_predicate duplicate, :valid?
    assert_includes duplicate.errors[:user_id], 'has already been taken'
  end

  def test_one_vote_per_owner_per_iteration_db_level
    AutospecApproval.create!(
      autospec_draft: @draft, user: @owner,
      iteration: 1, action: 'approved'
    )
    # `validate: false` skips the model-level uniqueness check AND skips
    # `before_validation :set_acted_at`, so we set acted_at by hand to
    # isolate the DB-level unique-index check.
    duplicate = AutospecApproval.new(
      autospec_draft: @draft, user: @owner,
      iteration: 1, action: 'rejected', reason: 'changed my mind',
      acted_at: Time.current
    )

    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  # Drive @draft through reject → resume → resubmit so current_iteration
  # is 2 and the previous (iteration=1) approval rows are stale.
  def cycle_to_iteration_two!
    @draft.mark_rejected!
    @draft.resume_from_rejection!
    @draft.submit_for_approval!
  end

  def test_same_owner_can_vote_on_different_iteration
    AutospecApproval.create!(autospec_draft: @draft, user: @owner,
                             iteration: 1, action: 'rejected', reason: 'too vague')
    cycle_to_iteration_two!
    second = AutospecApproval.create!(autospec_draft: @draft, user: @owner,
                                      iteration: @draft.current_iteration, action: 'approved')

    assert_equal 2, second.iteration
  end

  def test_acted_at_auto_stamped_on_create
    approval = AutospecApproval.create!(
      autospec_draft: @draft, user: @owner,
      iteration: 1, action: 'approved'
    )

    assert_not_nil approval.acted_at
    assert_in_delta Time.current, approval.acted_at, 5.seconds
  end

  def test_approved_predicate
    approval = AutospecApproval.new(action: 'approved')

    assert_predicate approval, :approved?
    refute_predicate approval, :rejected?
  end

  def test_rejected_predicate
    approval = AutospecApproval.new(action: 'rejected')

    assert_predicate approval, :rejected?
    refute_predicate approval, :approved?
  end
end

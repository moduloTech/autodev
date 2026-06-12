# frozen_string_literal: true

# An owner's vote on an AutospecDraft at a given iteration.
# See autodev/docs/autospec.md §E (state machine + iteration semantics)
# and §J (owner vs contributor matrix).
#
# Step 9 only defines the row + its invariants. The orchestration that
# creates these rows (one per owner, per draft, per iteration), checks
# quorum at the current iteration, and fires `mark_rejected!` or
# `finalize!` on the parent draft is step 11 work. Step 11 will own the
# "first rejection stops the vote" rule and the "all owners approved →
# finalize" rule.
#
# Invariants:
#   - one (draft, user, iteration) tuple ⇒ DB-unique index +
#     model-level uniqueness validation
#   - rejection requires a `reason`
#   - `iteration` ≥ 1 (the draft's iteration is bumped from 0 → 1 on
#     the first `submit_for_approval`, and every subsequent submit
#     increments further)
class AutospecApproval < ApplicationRecord
  ACTION_APPROVED = 'approved'
  ACTION_REJECTED = 'rejected'
  ACTIONS         = [ACTION_APPROVED, ACTION_REJECTED].freeze

  belongs_to :autospec_draft
  belongs_to :user

  validates :action, inclusion: { in: ACTIONS }
  validates :iteration, presence: true,
                        numericality: { only_integer: true, greater_than_or_equal_to: 1 }
  validates :reason, presence: true, if: :rejected?
  validates :user_id, uniqueness: { scope: %i[autospec_draft_id iteration] }
  validates :acted_at, presence: true

  before_validation :set_acted_at, on: :create

  def approved?
    action == ACTION_APPROVED
  end

  def rejected?
    action == ACTION_REJECTED
  end

  private

  def set_acted_at
    self.acted_at ||= Time.current
  end
end

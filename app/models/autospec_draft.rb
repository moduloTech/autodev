# frozen_string_literal: true

# A chat-driven future ticket — the central artefact of the AutoSpec feature.
# See autodev/docs/autospec.md §A (chat first-class + captures) for the
# product posture, §E for the lifecycle diagram, §G for the tool_calls
# that the model emits and the CSM applies, and §J for the matrix of
# who can do what.
#
# Step 9 lays down the schema + AASM skeleton. The orchestration service
# that records approvals and triggers `finalize!` when quorum is reached
# is step 11 work. For now, the model knows how to transition between
# states and which events are valid; it does not coordinate the owner
# votes or talk to GitLab.
class AutospecDraft < ApplicationRecord
  include AASM

  STATUS_DRAFTING         = 'drafting'
  STATUS_PENDING_APPROVAL = 'pending_approval'
  STATUS_REJECTED         = 'rejected'
  STATUS_SUBMITTED        = 'submitted'

  DESTINATION_HUMAN   = 'human'
  DESTINATION_AUTODEV = 'autodev'
  DESTINATIONS        = [DESTINATION_HUMAN, DESTINATION_AUTODEV].freeze

  # The migration declares `t.json :meta_chips, default: {}` — on SQLite
  # that maps to TEXT storage. The :json attribute type wires the
  # Hash ↔ JSON round-trip on reads/writes. Same pattern as
  # `AuditLog#payload`.
  attribute :meta_chips, :json, default: {}

  belongs_to :user
  belongs_to :project
  has_many :autospec_messages, dependent: :destroy
  has_many :autospec_attachments, dependent: :destroy
  has_many :autospec_approvals, dependent: :destroy

  validates :destination, inclusion: { in: DESTINATIONS, allow_nil: true }

  aasm column: :status, whiny_transitions: false do
    state :drafting, initial: true
    state :pending_approval
    state :rejected
    state :submitted

    after_all_transitions :persist_status_change!

    # Author clicks "Créer le ticket" → first submission OR re-submission
    # after a rejection/retract. The iteration is incremented up-front so
    # any approvals recorded by the orchestration service against this
    # transition's `pending_approval` window snapshot the new value.
    event :submit_for_approval do
      before { self.current_iteration += 1 }
      transitions from: :drafting, to: :pending_approval
    end

    # Author pulls the draft back out of approval to edit again. The
    # iteration is intentionally NOT decremented — the previous approvals
    # remain in the DB tagged with the older iteration so the audit trail
    # stays intact, but a subsequent `submit_for_approval` bumps the
    # iteration and the orchestration service ignores stale rows.
    event :retract do
      transitions from: :pending_approval, to: :drafting
    end

    # An owner rejected. The reason lives on the matching
    # AutospecApproval row, not on the draft itself.
    event :mark_rejected do
      transitions from: :pending_approval, to: :rejected
    end

    # Author resumes work after a rejection. Same iteration semantics as
    # `retract` — old approvals stay, next `submit_for_approval` bumps.
    event :resume_from_rejection do
      transitions from: :rejected, to: :drafting
    end

    # All owners approved at the current iteration. The orchestration
    # service that creates the GitLab issue + stamps `gitlab_issue_iid`
    # is step 11 work; the model just knows about the transition.
    event :finalize do
      transitions from: :pending_approval, to: :submitted
    end
  end

  # The User who created the draft. Distinct from owners voting on it —
  # owners are tracked via `autospec_approvals.user_id`. An owner-author
  # IS expected to validate their own draft per autospec.md §A
  # ("validation obligatoire de tous les owners, y compris l'auteur").
  def author
    user
  end

  # AASM after_all_transitions hook. Same `save!` pattern as Issue —
  # validation failures raise into the caller; the state machine cannot
  # silently drop a transition.
  def persist_status_change!
    save!
  end
end

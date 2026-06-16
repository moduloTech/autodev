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

  # ── Permission matrix (autospec.md §J) ───────────────────────────
  # The model owns these because they combine state + author + role —
  # all of which are draft-specific. Controllers call them; views call
  # them to decide which buttons to render.

  # Can this user see this draft on /autospec_drafts/:id ?
  # - admins: always
  # - author: always (any state)
  # - other contributors of the project: never (they can't see drafts
  #   they didn't author — even on a project they're a member of)
  # - other owners of the project: only once submitted for approval
  def viewable_by?(user)
    return false unless user
    return true if user.admin?
    return true if user_id == user.id
    return false unless user.owner_of?(project)

    pending_approval? || submitted? || rejected?
  end

  # Can this user edit / chat / apply suggestions on this draft?
  # Author-only, and only in `drafting`. Once submitted, the author
  # must `retract!` first.
  def editable_by?(user)
    user && user_id == user.id && drafting?
  end

  # Can this user submit the draft for approval?
  # Author + drafting (same as editable_by?, but spelled out for the
  # symmetry with retractable_by? + readability at call sites).
  def submittable_by?(user)
    editable_by?(user)
  end

  # Can this user choose the given destination at submission time?
  # Contributor-author: only 'human'. Owner-author: 'human' or
  # 'autodev'. Anything else → false (defence in depth — the
  # controller validates the same).
  def destination_choosable_by?(user, destination)
    return false unless DESTINATIONS.include?(destination)
    return false unless submittable_by?(user)
    return user.owner_of?(project) if destination == DESTINATION_AUTODEV

    user.contributor_of?(project)
  end

  # Can this user pull the draft back to `drafting` from
  # `pending_approval`? Author-only.
  def retractable_by?(user)
    user && user_id == user.id && pending_approval?
  end

  # Can this user record an approval/rejection on this draft right now?
  # Owner of the project + draft in `pending_approval`. Idempotency
  # (already voted at current_iteration) is checked at the recorder
  # level, not here — this predicate gates UI button visibility.
  def votable_by?(user)
    user && pending_approval? && user.owner_of?(project)
  end

  # AASM after_all_transitions hook. Same `save!` pattern as Issue —
  # validation failures raise into the caller; the state machine cannot
  # silently drop a transition.
  def persist_status_change!
    save!
  end
end

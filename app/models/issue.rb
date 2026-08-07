# frozen_string_literal: true

# Authoritative Issue model (railsification step 2 second half).
#
# Replaces the dynamically-built `Sequel::Model(db[:issues])` that
# `Database.build_model!` used to const_set at boot. AASM is now mounted on
# the ActiveRecord side via the aasm gem's adapter — same event/state DSL
# the legacy `IssueBehavior` module used. `save_changes` (Sequel) was
# replaced by AR's `save`, and the activity-event fan-out moved from a
# Sequel `after_create` hook on ActivityEvent to AR's `after_create_commit`
# (so SSE subscribers only see events the DB actually accepted).
class Issue < ApplicationRecord # rubocop:disable Metrics/ClassLength
  include AASM

  # The schema declares these columns as TEXT (legacy Sequel migrations used
  # `datetime('now')` SQLite expressions), so AR sees them as :string by
  # default. Declaring them :datetime hooks up the Time ↔ SQL conversion so
  # callers can pass Time.current / N.seconds.from_now and AR emits the same
  # 'YYYY-MM-DD HH:MM:SS' format that comparisons like `next_retry_at <=
  # datetime('now')` still understand.
  # `created_at` is in this list for the same reason: it's a TEXT column too,
  # so without the override AR would store `Time#to_s` ("… UTC") on the next
  # AR-written Issue, breaking any `date(created_at)`/`datetime(created_at)`
  # SQL the way it broke the activity_events sparkline.
  %i[started_at finished_at next_retry_at clarification_requested_at pipeline_poll_since
     infra_recheck_at error_recheck_at created_at].each do |col|
    attribute col, :datetime
  end

  # Guard flags set by the workflow classes before firing transitions.
  # They live on the instance rather than the DB because they describe
  # the operator-driven context of a single transition, not persistent
  # facts about the row. Same model the legacy IssueBehavior used.
  attr_writer :_issue_closed, :_skip_to_mr,
              :_unresolved_discussions_empty, :_post_completion,
              :_review_count_zero, :_review_count_over_zero,
              :_max_review_rounds_reached

  # Audit context set by IssuesController before firing a manual
  # transition. `_audit_origin == :manual` → the after_all_transitions
  # hook records `issue.transition_manual` with `_audit_actor` (which
  # itself may be nil until PR3 turns the gating on). Anything else
  # (e.g. transitions fired by AutodevPollJob workers) records
  # `issue.transition_auto` with NULL actor.
  attr_accessor :_audit_actor, :_audit_origin

  # The states that mean "autodev is working on it right now" — everything
  # between pickup and a terminal outcome, excluding the two waiting states
  # (`pending`, `needs_clarification`) and `answering_question`, which is a
  # read-only investigation rather than a delivery.
  #
  # Canonical here because the state machine below owns the vocabulary. The web
  # helpers used to read this list off the CLI display module (`Dashboard`),
  # which made every Rails request depend on lib/autodev being loaded — invisible
  # in production (the initializer requires it) but a 500 in any test booted
  # with AUTODEV_SKIP_LEGACY=1.
  ACTIVE_STATES = %w[
    cloning checking_spec implementing committing pushing
    creating_mr reviewing checking_pipeline
    fixing_discussions fixing_pipeline running_post_completion
  ].freeze

  aasm column: :status, whiny_transitions: false do # rubocop:disable Metrics/BlockLength
    state :pending, initial: true
    state :cloning, :checking_spec, :implementing, :committing, :pushing
    state :creating_mr, :reviewing, :checking_pipeline
    state :fixing_discussions, :fixing_pipeline, :running_post_completion
    state :answering_question, :needs_clarification
    state :done, :error, :closed

    after_all_transitions :persist_status_change!, :emit_activity_event!, :emit_audit_log!

    # === Happy path ===

    event(:start_processing) { transitions from: :pending, to: :cloning }
    event(:spec_clear)       { transitions from: :checking_spec, to: :implementing }
    event(:spec_unclear)     { transitions from: :checking_spec, to: :needs_clarification }
    event(:question_detected) { transitions from: :checking_spec, to: :answering_question }
    event(:question_answered) { transitions from: :answering_question, to: :done }

    event :clone_complete do
      transitions from: :cloning, to: :done,        guard: :issue_closed?
      transitions from: :cloning, to: :creating_mr, guard: :skip_to_mr?
      transitions from: :cloning, to: :checking_spec
    end

    event(:impl_complete)   { transitions from: :implementing, to: :committing }
    event(:commit_complete) { transitions from: :committing, to: :pushing }
    event(:push_complete)   { transitions from: :pushing, to: :creating_mr }
    event(:mr_created)      { transitions from: :creating_mr, to: :checking_pipeline }

    # === Pipeline monitoring ===

    event :pipeline_green do
      transitions from: :checking_pipeline, to: :done, guard: :max_review_rounds_reached?
      transitions from: :checking_pipeline, to: :reviewing, guard: :review_count_zero?
      transitions from: :checking_pipeline, to: :done,
                  guard: %i[review_count_over_zero? no_unresolved_discussions?]
      transitions from: :checking_pipeline, to: :fixing_discussions, guard: :review_count_over_zero?
    end

    event(:post_completion_done)  { transitions from: :running_post_completion, to: :done }
    event(:start_post_completion) { transitions from: :done, to: :running_post_completion }
    event(:review_done)           { transitions from: :reviewing, to: :checking_pipeline }
    event(:review_giveup)         { transitions from: :reviewing, to: :done }
    event(:pipeline_failed_code)  { transitions from: :checking_pipeline, to: :fixing_pipeline }
    event(:mr_closed)             { transitions from: :checking_pipeline, to: :done }

    # === Fix cycles, clarification, reentry ===

    event(:discussions_fixed)        { transitions from: :fixing_discussions, to: :checking_pipeline }
    event(:pipeline_fix_done)        { transitions from: :fixing_pipeline, to: :checking_pipeline }
    event(:clarification_received)   { transitions from: :needs_clarification, to: :pending }
    event(:reenter)                  { transitions from: :done, to: :pending }
    event(:reenter_to_check_pipeline) { transitions from: :done, to: :checking_pipeline }

    # === Error handling ===

    event :mark_failed do
      transitions from: %i[cloning checking_spec implementing committing
                           pushing creating_mr reviewing
                           fixing_discussions fixing_pipeline
                           running_post_completion answering_question],
                  to: :error
    end

    event(:retry_processing) { transitions from: :error, to: :pending }
    event(:retry_pipeline)   { transitions from: :error, to: :checking_pipeline }

    # === Manual close ===
    #
    # A project collaborator can manually close a ticket from any state
    # (IssuesController#close, gated on project membership). `closed` is
    # terminal — the poller skips any status != 'pending'. Reopen via the
    # manual #reset action, which forces the row back to `pending`.
    event :close do
      transitions from: %i[pending cloning checking_spec implementing committing
                           pushing creating_mr reviewing checking_pipeline
                           fixing_discussions fixing_pipeline running_post_completion
                           answering_question needs_clarification done error],
                  to: :closed
    end
  end

  # -- Guard methods (read the instance flags set by the workflow) --

  def issue_closed?
    @_issue_closed == true
  end

  def skip_to_mr?
    @_skip_to_mr == true
  end

  def no_unresolved_discussions?
    @_unresolved_discussions_empty == true
  end

  def post_completion?
    @_post_completion == true
  end

  def review_count_zero?
    @_review_count_zero == true
  end

  def review_count_over_zero?
    @_review_count_over_zero == true
  end

  def max_review_rounds_reached?
    @_max_review_rounds_reached == true
  end

  # -- AASM callbacks --

  # Sequel had `save_changes` which only emits an UPDATE for dirty columns;
  # AR's `save` does the same automatically (via the dirty-tracking layer).
  # We use `save!` so a validation failure surfaces — the state machine
  # cannot silently drop a transition.
  def persist_status_change!
    save!
  end

  # Best-effort: record every AASM transition as an `activity_events` row.
  # Failures must never break the state machine, so any error is swallowed.
  def emit_activity_event!
    payload = JSON.generate(from: aasm.from_state.to_s, to: aasm.to_state.to_s,
                            event: aasm.current_event.to_s.delete_suffix('!'))
    ActivityEvent.create(issue_id: id, kind: 'transition', level: 'info', payload_json: payload)
  rescue StandardError
    nil
  end

  # Audit-log fan-out. Manual transitions (set by IssuesController#transition)
  # carry the acting user; everything else (poller-driven, job-driven, AASM
  # transitions fired by workflow classes) records as automatic with a NULL
  # actor. Best-effort: never raises into the AASM callback chain. The
  # ensure clause clears the manual flags so a subsequent transition on the
  # same instance does not inherit them.
  def emit_audit_log! # rubocop:disable Metrics/MethodLength
    origin = @_audit_origin == :manual ? :manual : :automatic
    action = origin == :manual ? 'issue.transition_manual' : 'issue.transition_auto'
    Audit.record!(
      resource: self,
      action: action,
      actor: @_audit_actor,
      payload: {
        project_path: project_path,
        iid: issue_iid,
        event: aasm.current_event.to_s.delete_suffix('!'),
        from: aasm.from_state.to_s,
        to: aasm.to_state.to_s
      }
    )
  rescue StandardError
    nil
  ensure
    @_audit_actor = nil
    @_audit_origin = nil
  end

  # -- Startup recovery --
  #
  # Resets issues stuck in transient states after a crash. Called from
  # `bin/autodev` on boot. Idempotent — running with no stuck rows is a
  # no-op. Returns the total number of rows touched (for the log line).
  #
  # Errors with an existing MR resume at checking_pipeline; without an
  # MR, back at pending. Stuck active states (cloning..creating_mr) and
  # `reviewing`/`fixing_pipeline`/`running_post_completion` are reset to
  # their best resume point. Same rules as the legacy Sequel
  # `Database::Recovery` module had — ported verbatim to AR semantics.
  def self.recover_on_startup!(max_retries:)
    recover_errored!(max_retries) +
      recover_fixing_pipeline! +
      recover_reviewing! +
      recover_post_completion! +
      recover_stuck_processing!
  end

  RECOVERABLE_ACTIVE_STATES = %w[cloning checking_spec implementing committing pushing creating_mr].freeze

  def self.recover_errored!(max_retries)
    retryable = where(status: 'error')
                .where('retry_count <= ?', max_retries)
                .where("next_retry_at IS NULL OR next_retry_at <= datetime('now')")
    # `reset_budget: false` on purpose: this is automatic crash recovery, not an
    # operator decision. Handing out a fresh budget here would restart a
    # genuinely broken ticket on every single boot.
    reset_for_retry!(retryable)
  end

  # Single source of truth for putting a row back into a state the poller will
  # actually pick up again (Autodev #34, item 3). Returns the number of rows
  # touched. Bypasses AASM deliberately — like every other recovery/reset path,
  # this is an out-of-band correction, not a workflow transition.
  #
  # Two halves, and both matter:
  #
  # - A row that already has an MR resumes at `checking_pipeline`, which
  #   `dispatch_pipelines` polls unconditionally. Sending it back to `pending`
  #   instead would re-implement from scratch over an existing MR.
  # - A pre-MR row restarts as `pending` and **must** carry a due
  #   `next_retry_at`: `fetch_retryable` requires a non-NULL stamp, and
  #   `dispatch_new_issues` only rediscovers `labels_todo` while an errored
  #   ticket still carries `label_doing`. Without the stamp the row is orphaned
  #   in `pending` — task #26's exact pattern.
  #
  # Three call sites used to re-derive this rule and disagreed: the CLI
  # `--reset` had it right, `recover_errored!` dropped the stamp, and
  # `IssuesController#reset` dropped both the stamp and the split. Hence one
  # method rather than a fourth chance to get it wrong.
  #
  # `reset_budget:` zeroes `retry_count` — for an operator-driven reset, which
  # means "clean slate". `clear_attention:` also clears the needs_attention
  # trio, for the same reason.
  def self.reset_for_retry!(scope, reset_budget: false, clear_attention: false)
    fields = { error_message: nil, started_at: nil }
    fields[:retry_count] = 0 if reset_budget
    fields.merge!(needs_attention: false, attention_reason: nil, attention_detail: nil) if clear_attention

    scope.where.not(mr_iid: nil).update_all(**fields, status: 'checking_pipeline', next_retry_at: nil) +
      scope.where(mr_iid: nil).update_all(**fields, status: 'pending', next_retry_at: Time.current)
  end

  def self.recover_fixing_pipeline!
    where(status: 'fixing_pipeline').update_all(status: 'checking_pipeline')
  end

  def self.recover_reviewing!
    where(status: 'reviewing').update_all(status: 'checking_pipeline')
  end

  def self.recover_post_completion!
    where(status: 'running_post_completion').update_all(status: 'done', finished_at: Time.current)
  end

  def self.recover_stuck_processing!
    stuck = where(status: RECOVERABLE_ACTIVE_STATES)
    # The pre-MR branch resets to `pending`, but the GitLab label is still
    # `label_doing` (set when processing started) — so `dispatch_new_issues`,
    # which only re-discovers `labels_todo` issues, will never re-enqueue it.
    # Stamp `next_retry_at` so `dispatch_retries` picks it up via `:retry_stuck`
    # on the next poll; otherwise the row is orphaned in `pending` forever.
    stuck.where.not(mr_iid: nil).update_all(status: 'checking_pipeline', started_at: nil) +
      stuck.where(mr_iid: nil).update_all(status: 'pending', started_at: nil, next_retry_at: Time.current)
  end

  private_class_method :recover_errored!, :recover_fixing_pipeline!, :recover_reviewing!,
                       :recover_post_completion!, :recover_stuck_processing!
end

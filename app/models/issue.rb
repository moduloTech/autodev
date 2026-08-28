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
     infra_recheck_at created_at].each do |col|
    attribute col, :datetime
  end

  # Guard flags set by the workflow classes before firing transitions.
  # They live on the instance rather than the DB because they describe
  # the operator-driven context of a single transition, not persistent
  # facts about the row. Same model the legacy IssueBehavior used.
  attr_writer :_issue_closed, :_skip_to_mr,
              :_unresolved_discussions_empty, :_post_completion,
              :_review_count_zero, :_review_count_over_zero

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

  # The states a `:process` cycle may start from — the two waiting states, and
  # only those. Read by `PollRouter#route_by_state`, which decides whether a
  # discovered GitLab issue reaches `PollDispatcher#process_issue` at all, and by
  # `IssueProcessJob::DISPATCHED_FROM`, which refuses a dispatch whose row has
  # moved on since (Autodev #61).
  #
  # One declaration because the two disagreed, silently and for months (Autodev
  # #75): the job already accepted `needs_clarification`, the router did not, and
  # the narrower of the two wins by dropping the row. `process_issue` is the only
  # code that ever asks whether the human answered, so a row the router refuses is
  # a question that is never re-read — 12 production tickets, the oldest waiting
  # since 15/05/2026.
  PROCESSABLE_STATES = %w[pending needs_clarification].freeze

  aasm column: :status, whiny_transitions: false do # rubocop:disable Metrics/BlockLength
    state :pending, initial: true
    state :cloning, :checking_spec, :implementing, :committing, :pushing
    state :creating_mr, :reviewing, :checking_pipeline
    state :fixing_discussions, :fixing_pipeline, :running_post_completion
    state :answering_question, :needs_clarification
    state :done, :error, :closed

    # `stamp_pipeline_watch!` is first on purpose: it only assigns, and
    # `persist_status_change!` right after is the save that writes it.
    after_all_transitions :stamp_pipeline_watch!, :persist_status_change!,
                          :emit_activity_event!, :emit_audit_log!

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

    # === Giving up ===
    #
    # The single point at which autodev stops working a ticket short of a nominal
    # delivery (Autodev #60, item 2). Four call sites used to write
    # `status: 'done'` themselves — pipeline stagnation, discussion stagnation, an
    # expired pipeline watch, the review-round limit — so none of them produced a
    # `transition` row, none appeared in the activity journal or the audit log, and
    # none of the callbacks below ran: that is what left the stale
    # `checking_pipeline_since` clock Autodev #53 had to patch at each site.
    #
    # `IssueAbandonment#abandon_issue` is the only caller. The *reason* stays
    # per-site (`attention_reason`) because `dispatch_infra_recheck` selects
    # `stagnation_pipeline` and must not re-arm rows given up for another cause;
    # only the mechanics are shared.
    # `reviewing` joined the sources with Autodev #81. `green_first_review` fires
    # `pipeline_green!` before calling the review, so a give-up decided *inside*
    # the review starts from `reviewing` — and until then the only such give-up,
    # `review_giveup`, had its own event and its own end. A declared review skill
    # missing from the clone is the second, and it must stop the request from
    # exactly there: leaving it in `reviewing` is what made Autodev #81's request
    # invisible to every dispatch pass, and handing it back to `checking_pipeline`
    # is the unbounded loop that ticket refuses.
    event(:abandon) { transitions from: %i[checking_pipeline fixing_discussions reviewing], to: :done }

    # === Fix cycles, clarification, reentry ===

    event(:discussions_fixed)        { transitions from: :fixing_discussions, to: :checking_pipeline }
    event(:pipeline_fix_done)        { transitions from: :fixing_pipeline, to: :checking_pipeline }
    event(:clarification_received)   { transitions from: :needs_clarification, to: :pending }
    # `closed` is a reentry source since Autodev #52: a stop decided by a human
    # (unassignment or a workflow-label handover) now ends in `closed` rather
    # than `done`, and the documented way back — repose the todo label, reassign
    # autodev — has to keep working. `PollRouter#reenterable?` guards which
    # `closed` rows qualify; the state machine only says the move is legal.
    event(:reenter)                  { transitions from: %i[done closed], to: :pending }
    event(:reenter_to_check_pipeline) { transitions from: %i[done closed], to: :checking_pipeline }

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
    # (IssuesController#close, gated on project membership). Autodev also closes
    # a row itself when GitLab says the ticket is gone, when it has been
    # unassigned, or when a human moved its workflow label (Autodev::ExternalState).
    #
    # `closed` is *almost* terminal: the poller skips any status != 'pending',
    # and the only automatic way back is reposing a todo label **after** the row
    # was closed (PollRouter#reenterable? — Autodev #52), which is what keeps a
    # human-decided stop from being a trap while leaving the dashboard's close
    # button an off-switch. Otherwise reopen via the manual #reset action, which
    # forces the row back to `pending`.
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

  # -- AASM callbacks --

  # The clock the absolute pipeline-watch bound reads (Autodev #53). One
  # callback rather than a clear at each of the six exits from
  # `checking_pipeline`, because "reset on any transition" is exactly the
  # semantics the bound needs: it gives up after N days *without a transition*,
  # so a row that ping-pongs through a fix cycle keeps restarting the clock —
  # correctly, since that row is moving and stagnation detection is what bounds
  # it.
  #
  # Not `pipeline_poll_since`, which `clear_pipeline_poll_since` resets whenever
  # a poll resolves to green or red — including the infra-red case that stays in
  # the state. That column measures consecutive unresolved polls, the one
  # quantity that never bounds an infra loop.
  #
  # The two `update_all` writers that set this status (`reset_for_retry!`,
  # `revive_stalled!`) bypass AASM and clear the column explicitly;
  # `PipelineMonitor::PollTracker` seeds it at the first poll. They clear rather
  # than leave it alone because an untouched column can still be carrying the
  # clock of a watch that ended months ago, which the lazy seed would then keep
  # (it only fills NULL). Every *workflow* exit from `checking_pipeline` does go
  # through AASM since Autodev #60 — the give-up paths that used to write
  # `status: 'done'` themselves now fire the `abandon` event — so this callback is
  # the single owner of the column and those two `update_all` writers are the only
  # remaining bypass.
  def stamp_pipeline_watch!
    self.checking_pipeline_since = aasm.to_state == :checking_pipeline ? Time.current : nil
  end

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
  # Errors resolve via `recover_errored!`; every other stalled active state
  # goes through `revive_stalled!` — see its comment for the per-state rules.
  def self.recover_on_startup!(max_retries:)
    recover_errored!(max_retries) + revive_stalled!(where(status: STALLED_STATES))
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

    scope.where.not(mr_iid: nil)
         .update_all(**fields, status: 'checking_pipeline', next_retry_at: nil, checking_pipeline_since: nil) +
      scope.where(mr_iid: nil).update_all(**fields, status: 'pending', next_retry_at: Time.current)
  end

  # How each stalled state gets back onto a path the poller walks. The rules are
  # not uniform, which is the whole reason this lives in one place:
  #
  # - pre-MR work restarts as `pending` **with a stamp** (`reset_for_retry!`
  #   owns that split — see its comment; without the stamp the row is orphaned
  #   because the GitLab label is still `label_doing`);
  # - post-MR work resumes at `checking_pipeline`, which `dispatch_pipelines`
  #   polls unconditionally and where `PipelineMonitor` re-derives what is left
  #   to do — including whether discussions remain;
  # - `running_post_completion` carries an MR yet must end as `done`: the hook
  #   is non-fatal and is deliberately not replayed.
  #
  # Two call sites: `recover_on_startup!` (a worker died and the service
  # restarted) and `dispatch_dormant_audit` (a worker was pruned and the service
  # did *not* restart — Autodev #47). `answering_question` and
  # `fixing_discussions` are new here: HealthReport monitors them, but boot
  # recovery had no rule for either, so a row frozen in one survived a restart.
  REVIVE_TO_PENDING = (RECOVERABLE_ACTIVE_STATES + %w[answering_question]).freeze
  REVIVE_TO_PIPELINE = %w[reviewing fixing_pipeline fixing_discussions].freeze
  REVIVE_TO_DONE = %w[running_post_completion].freeze
  STALLED_STATES = (REVIVE_TO_PENDING + REVIVE_TO_PIPELINE + REVIVE_TO_DONE).freeze

  def self.revive_stalled!(scope)
    reset_for_retry!(scope.where(status: REVIVE_TO_PENDING)) +
      scope.where(status: REVIVE_TO_PIPELINE)
           .update_all(status: 'checking_pipeline', started_at: nil, checking_pipeline_since: nil) +
      scope.where(status: REVIVE_TO_DONE).update_all(status: 'done', finished_at: Time.current)
  end

  private_class_method :recover_errored!

  # A row that has stopped moving: no activity_events entry since `cutoff`.
  # The trailing `created_at: ...cutoff` is applied unconditionally, not as a
  # conditional fallback — it is equivalent to "no activity, or its only
  # activity predates cutoff" only because an event's created_at is always >=
  # its issue's created_at (an issue can't emit before it exists). That
  # invariant is what lets one AND-ed clause stand in for both "never emitted"
  # and "emitted, but a while ago".
  #
  # Single source of truth for two readers that must never disagree —
  # HealthReport's stuck-issues card and `dispatch_dormant_audit` (Autodev #47).
  # A card that flags what no pass acts on is how 14 rows sat frozen since April.
  #
  # The subquery is bounded to `all.select(:id)` — the issues already selected
  # by the outer relation — on purpose, not just for `issue_id: nil` NULL
  # safety. activity_events only indexes `(issue_id, created_at)`
  # (`idx_ae_issue`); with no index leading on `created_at`, scanning by time
  # window alone forces a full covering-index scan of the whole (write-heavy,
  # ever-growing) table. Bounding by the candidate issue_ids first lets SQLite
  # seek `idx_ae_issue` per id instead. Do not widen this to an unbounded
  # time-window scan, and do not add a `created_at`-leading index to make one
  # cheap — the extra index would tax every activity_events write for a query
  # this bound already makes fast.
  #
  # `issue_id: nil` is excluded explicitly, even though the `issue_id IN
  # (real ids)` bound above already drops NULL rows as a side effect (SQL:
  # `NULL IN (...)` is NULL, never true). Kept spelled out because it is the
  # actual reason this scope is safe at all: activity_events holds issue-less
  # rows ('poller', 'usage'), and a single NULL surviving into the outer
  # `NOT IN` collapses that clause to the empty set for every row. Anyone
  # loosening the bound above must not lose this exclusion along with it.
  scope :without_activity_since, lambda { |cutoff|
    recent = ActivityEvent.where.not(issue_id: nil)
                          .where(issue_id: all.select(:id))
                          .where(created_at: cutoff..)
                          .select(:issue_id)
    where.not(id: recent).where(created_at: ...cutoff)
  }
end

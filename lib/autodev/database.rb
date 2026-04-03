# frozen_string_literal: true

module Database
  @db = nil

  def self.connect(url)
    return unless url

    if url.start_with?("sqlite://")
      db_path = url.sub("sqlite://", "")
      db_path = File.expand_path(db_path)
      url = "sqlite://#{db_path}"
      FileUtils.mkdir_p(File.dirname(db_path))
    end

    @db = Sequel.connect(url, max_connections: 5)
    @db.run("PRAGMA journal_mode=WAL")
    @db.run("PRAGMA busy_timeout=5000")
    migrate!
    migrate_statuses!
    true
  rescue Sequel::DatabaseConnectionError, Sequel::DatabaseError => e
    warn "  Database connection failed: #{e.message}"
    @db = nil
    false
  end

  def self.connected?
    !@db.nil?
  end

  def self.disconnect
    @db&.disconnect
    @db = nil
  end

  def self.db
    @db
  end

  # -- Schema migration --

  def self.migrate!
    @db.run <<~SQL
      CREATE TABLE IF NOT EXISTS issues (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        project_path  TEXT NOT NULL,
        issue_iid     INTEGER NOT NULL,
        issue_title   TEXT,
        branch_name   TEXT,
        status        TEXT NOT NULL DEFAULT 'pending',
        mr_iid        INTEGER,
        mr_url        TEXT,
        error_message TEXT,
        dc_stdout      TEXT,
        dc_stderr      TEXT,
        retry_count    INTEGER NOT NULL DEFAULT 0,
        fix_round      INTEGER NOT NULL DEFAULT 0,
        next_retry_at  TEXT,
        clarification_requested_at TEXT,
        pipeline_retrigger_count INTEGER NOT NULL DEFAULT 0,
        started_at     TEXT,
        finished_at    TEXT,
        created_at     TEXT NOT NULL DEFAULT (datetime('now')),
        UNIQUE(project_path, issue_iid)
      );
    SQL

    # Add columns for existing databases
    %w[dc_stdout dc_stderr].each do |col|
      @db.run("ALTER TABLE issues ADD COLUMN #{col} TEXT") rescue nil
    end
    @db.run("ALTER TABLE issues ADD COLUMN retry_count INTEGER NOT NULL DEFAULT 0") rescue nil
    @db.run("ALTER TABLE issues ADD COLUMN next_retry_at TEXT") rescue nil
    @db.run("ALTER TABLE issues ADD COLUMN clarification_requested_at TEXT") rescue nil
    @db.run("ALTER TABLE issues ADD COLUMN fix_round INTEGER NOT NULL DEFAULT 0") rescue nil
    @db.run("ALTER TABLE issues ADD COLUMN pipeline_retrigger_count INTEGER NOT NULL DEFAULT 0") rescue nil
    @db.run("ALTER TABLE issues ADD COLUMN issue_author_id INTEGER") rescue nil
    @db.run("ALTER TABLE issues ADD COLUMN post_completion_error TEXT") rescue nil
  end

  # -- Status migration from pre-AASM names --

  def self.migrate_statuses!
    {
      "mr_pipeline_running" => "checking_pipeline",
      "mr_fixing"           => "fixing_discussions",
      "mr_pipeline_fixing"  => "fixing_pipeline"
    }.each do |old_status, new_status|
      @db[:issues].where(status: old_status).update(status: new_status)
    end

    @db[:issues].where(status: %w[done mr_fixed]).exclude(mr_iid: nil).update(status: "checking_pipeline")
    @db[:issues].where(status: %w[done mr_fixed]).update(status: "over")
  end

  # -- Build Issue Sequel::Model with AASM --

  def self.build_model!
    # Name the class BEFORE including AASM. AASM's StateMachineStore keys by
    # klass.to_s — if the class is anonymous at registration time, the key is
    # "#<Class:0x...>" but lookups after const_set use "Issue", causing a mismatch.
    klass = Class.new(Sequel::Model(db[:issues]))
    Object.const_set(:Issue, klass)

    klass.class_eval do
      include AASM

      attr_writer :_issue_closed, :_skip_to_mr, :_max_fix_rounds, :_unresolved_discussions_empty, :_has_post_completion

      aasm column: :status, whiny_transitions: false do
        state :pending, initial: true
        state :cloning
        state :checking_spec
        state :implementing
        state :committing
        state :pushing
        state :creating_mr
        state :reviewing
        state :checking_pipeline
        state :fixing_discussions
        state :fixing_pipeline
        state :running_post_completion
        state :answering_question
        state :needs_clarification
        state :over
        state :blocked
        state :error

        after_all_transitions :persist_status_change!

        # === Happy path: issue → MR ===

        event :start_processing do
          transitions from: :pending, to: :cloning
        end

        event :clone_complete do
          transitions from: :cloning, to: :over, guard: :issue_closed?
          transitions from: :cloning, to: :creating_mr, guard: :skip_to_mr?
          transitions from: :cloning, to: :checking_spec
        end

        event :spec_clear do
          transitions from: :checking_spec, to: :implementing
        end

        event :spec_unclear do
          transitions from: :checking_spec, to: :needs_clarification
        end

        event :question_detected do
          transitions from: :checking_spec, to: :answering_question
        end

        event :question_answered do
          transitions from: :answering_question, to: :over
        end

        event :impl_complete do
          transitions from: :implementing, to: :committing
        end

        event :commit_complete do
          transitions from: :committing, to: :pushing
        end

        event :push_complete do
          transitions from: :pushing, to: :creating_mr
        end

        event :mr_created do
          transitions from: :creating_mr, to: :reviewing
        end

        event :review_complete do
          transitions from: :reviewing, to: :checking_pipeline
        end

        # === Pipeline monitoring ===

        event :pipeline_green do
          transitions from: :checking_pipeline, to: :running_post_completion, guard: %i[no_unresolved_discussions? has_post_completion?]
          transitions from: :checking_pipeline, to: :over, guard: :no_unresolved_discussions?
          transitions from: :checking_pipeline, to: :running_post_completion, guard: %i[max_fix_rounds_reached? has_post_completion?]
          transitions from: :checking_pipeline, to: :over, guard: :max_fix_rounds_reached?
          transitions from: :checking_pipeline, to: :fixing_discussions
        end

        event :post_completion_done do
          transitions from: :running_post_completion, to: :over
        end

        event :pipeline_failed_code do
          transitions from: :checking_pipeline, to: :fixing_pipeline, guard: :can_fix?
          transitions from: :checking_pipeline, to: :blocked
        end

        event :pipeline_failed_infra do
          transitions from: :checking_pipeline, to: :blocked
        end

        event :pipeline_canceled do
          transitions from: :checking_pipeline, to: :blocked
        end

        # === Fix cycles ===

        event :discussions_fixed do
          transitions from: :fixing_discussions, to: :checking_pipeline
        end

        event :pipeline_fix_done do
          transitions from: :fixing_pipeline, to: :checking_pipeline
        end

        # === Clarification ===

        event :clarification_received do
          transitions from: :needs_clarification, to: :pending
        end

        # === Resume from over (label workflow) ===

        event :resume_todo do
          transitions from: :over, to: :pending
        end

        event :resume_mr do
          transitions from: :over, to: :fixing_discussions
        end

        # === Error handling ===

        event :mark_failed do
          transitions from: [:cloning, :checking_spec, :implementing, :committing,
                             :pushing, :creating_mr, :reviewing,
                             :fixing_discussions, :fixing_pipeline,
                             :running_post_completion, :answering_question], to: :error
        end

        event :retry_processing do
          transitions from: :error, to: :pending
        end

        event :retry_pipeline do
          transitions from: :error, to: :checking_pipeline
        end
      end

      # -- Guard methods --

      def issue_closed?
        @_issue_closed == true
      end

      def skip_to_mr?
        @_skip_to_mr == true
      end

      def no_unresolved_discussions?
        @_unresolved_discussions_empty == true
      end

      def max_fix_rounds_reached?
        fix_round >= (@_max_fix_rounds || 3)
      end

      def can_fix?
        fix_round < (@_max_fix_rounds || 3)
      end

      def has_post_completion?
        @_has_post_completion == true
      end

      # -- Persistence callback --

      def persist_status_change!
        save_changes
      end
    end
  end

  # -- Startup recovery --

  def self.recover_on_startup!(max_retries:)
    return 0 unless connected?

    # Errors with an existing MR resume at checking_pipeline, not pending
    count_mr = db[:issues]
      .where(status: "error")
      .where { retry_count < max_retries }
      .where { Sequel.lit("next_retry_at IS NULL OR next_retry_at <= datetime('now')") }
      .exclude(mr_iid: nil)
      .update(status: "checking_pipeline", error_message: nil, started_at: nil)

    count_no_mr = db[:issues]
      .where(status: "error")
      .where { retry_count < max_retries }
      .where { Sequel.lit("next_retry_at IS NULL OR next_retry_at <= datetime('now')") }
      .where(mr_iid: nil)
      .update(status: "pending", error_message: nil, started_at: nil)

    count = count_mr + count_no_mr

    count2 = db[:issues]
      .where(status: "fixing_pipeline")
      .update(status: "checking_pipeline")

    count3 = db[:issues]
      .where(status: "running_post_completion")
      .update(status: "over", finished_at: Sequel.lit("datetime('now')"))

    # Reset issues stuck in active processing states (e.g. after crash during label_doing)
    count4 = db[:issues]
      .where(status: %w[cloning checking_spec implementing committing pushing creating_mr])
      .update(status: "pending", started_at: nil)

    (count || 0) + (count2 || 0) + (count3 || 0) + (count4 || 0)
  end
end

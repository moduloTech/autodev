# frozen_string_literal: true

module Database
  # Schema creation and column migrations for the issues table.
  module Migration
    CREATE_TABLE_SQL = <<~SQL
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

    OPTIONAL_COLUMNS = [
      'dc_stdout TEXT',
      'dc_stderr TEXT',
      'retry_count INTEGER NOT NULL DEFAULT 0',
      'next_retry_at TEXT',
      'clarification_requested_at TEXT',
      'fix_round INTEGER NOT NULL DEFAULT 0',
      'pipeline_retrigger_count INTEGER NOT NULL DEFAULT 0',
      'issue_author_id INTEGER',
      'post_completion_error TEXT',
      "locale TEXT DEFAULT 'fr'"
    ].freeze

    STATUS_RENAMES = {
      'mr_pipeline_running' => 'checking_pipeline',
      'mr_fixing' => 'fixing_discussions',
      'mr_pipeline_fixing' => 'fixing_pipeline'
    }.freeze

    def self.run(db)
      db.run(CREATE_TABLE_SQL)
      add_missing_columns!(db)
    end

    def self.add_missing_columns!(db)
      OPTIONAL_COLUMNS.each do |col_def|
        db.run("ALTER TABLE issues ADD COLUMN #{col_def}")
      rescue StandardError
        nil
      end
    end

    def self.migrate_statuses!(db)
      STATUS_RENAMES.each do |old_status, new_status|
        db[:issues].where(status: old_status).update(status: new_status)
      end

      db[:issues].where(status: %w[done mr_fixed]).exclude(mr_iid: nil).update(status: 'checking_pipeline')
      db[:issues].where(status: %w[done mr_fixed]).update(status: 'over')
    end

    private_class_method :add_missing_columns!
  end
end

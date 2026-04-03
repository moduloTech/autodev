# frozen_string_literal: true

module Database
  # Startup recovery: resets issues stuck in transient states after a crash.
  module Recovery
    def self.run(db, max_retries)
      count = recover_errored!(db, max_retries)
      count += recover_fixing_pipeline!(db)
      count += recover_post_completion!(db)
      count + recover_stuck_processing!(db)
    end

    # Errors with an existing MR resume at checking_pipeline, not pending
    def self.recover_errored!(db, max_retries)
      retryable = db[:issues]
                  .where(status: 'error')
                  .where { retry_count < max_retries }
                  .where { Sequel.lit("next_retry_at IS NULL OR next_retry_at <= datetime('now')") }

      count_mr = retryable.exclude(mr_iid: nil)
                          .update(status: 'checking_pipeline', error_message: nil, started_at: nil)
      count_no_mr = retryable.where(mr_iid: nil)
                             .update(status: 'pending', error_message: nil, started_at: nil)

      (count_mr || 0) + (count_no_mr || 0)
    end

    def self.recover_fixing_pipeline!(db)
      db[:issues].where(status: 'fixing_pipeline').update(status: 'checking_pipeline') || 0
    end

    def self.recover_post_completion!(db)
      db[:issues]
        .where(status: 'running_post_completion')
        .update(status: 'over', finished_at: Sequel.lit("datetime('now')")) || 0
    end

    # Reset issues stuck in active processing states (e.g. after crash during label_doing)
    def self.recover_stuck_processing!(db)
      db[:issues]
        .where(status: %w[cloning checking_spec implementing committing pushing creating_mr])
        .update(status: 'pending', started_at: nil) || 0
    end

    private_class_method :recover_errored!, :recover_fixing_pipeline!,
                         :recover_post_completion!, :recover_stuck_processing!
  end
end

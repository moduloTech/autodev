# frozen_string_literal: true

class PipelineMonitor
  # Error recovery for pipeline evaluation/fix failures.
  module ErrorHandler
    private

    def handle_rate_limit(issue, error)
      wait = error.wait_seconds
      log_error "Issue ##{issue.issue_iid}: rate limit hit, parking for #{wait}s"
      safe_mark_failed!(issue)
      Issue.where(id: issue.id).update(
        error_message: error.message, dc_stdout: @dc_stdout, dc_stderr: @dc_stderr,
        next_retry_at: Sequel.lit("datetime('now', '+#{wait} seconds')")
      )
    end

    def handle_failure_error(issue, error)
      bt = error.backtrace&.first(10)&.join("\n  ")
      log_error "Pipeline evaluation/fix failed: #{error.class}: #{error.message}"
      log_error "  #{bt}" if bt
      safe_mark_failed!(issue)
      issue.update(error_message: "Pipeline fix error: #{error.class}: #{error.message}\n  #{bt}",
                   dc_stdout: @dc_stdout, dc_stderr: @dc_stderr)
      notify_localized(issue.issue_iid, :pipeline_fix_error, error: "#{error.class}: #{error.message[0, 200]}")
    end

    def safe_mark_failed!(issue)
      issue.mark_failed!
    rescue AASM::InvalidTransition
      issue.update(status: 'error')
    end
  end
end

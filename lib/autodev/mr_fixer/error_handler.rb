# frozen_string_literal: true

class MrFixer
  # Error handling helpers for MR fix cycles.
  module ErrorHandler
    private

    def handle_rate_limit(issue, error)
      wait = error.wait_seconds
      log_error "MR !#{issue.mr_iid}: rate limit hit, parking for #{wait}s"
      safe_mark_failed!(issue)
      Issue.where(id: issue.id).update_all(
        error_message: error.message,
        dc_stdout: @dc_stdout, dc_stderr: @dc_stderr,
        next_retry_at: wait.to_i.seconds.from_now
      )
      log_activity(issue, :rate_limit, wait: wait)
    end

    # Claude credentials are dead — see IssueProcessor::ErrorHandler#handle_auth_failure.
    # No retry is scheduled and no per-ticket comment is posted.
    def handle_auth_failure(issue, error)
      log_error "MR !#{issue.mr_iid}: Claude authentication failed, manual intervention required"
      safe_mark_failed!(issue)
      Issue.where(id: issue.id).update_all(
        error_message: "#{error.class}: #{error.message}",
        dc_stdout: @dc_stdout, dc_stderr: @dc_stderr
      )
      log_activity(issue, :auth_failure)
    end

    def handle_fix_error(issue, error)
      return handle_auth_failure(issue, error) if error.is_a?(AuthenticationError)
      # Before every write below — the row belongs to a human now (Autodev #97).
      return stop_on_stale_transition(error) if error.is_a?(StaleTransitionError)

      bt = error.backtrace&.first(10)&.join("\n  ")
      safe_mark_failed!(issue)
      persist_and_notify_fix_error(issue, error, bt)
      log_error "MR fix failed: #{error.class}: #{error.message}"
      log_error "  #{bt}" if bt
    end

    def persist_and_notify_fix_error(issue, error, backtrace)
      issue.update(error_message: "MR fix error: #{error.class}: #{error.message}\n  #{backtrace}",
                   dc_stdout: @dc_stdout, dc_stderr: @dc_stderr)
      summary = "#{error.class}: #{error.message[0, 200]}"
      notify_localized(issue.issue_iid, :mr_fix_error, error: summary)
      log_activity(issue, :error, error: summary)
    end
  end
end

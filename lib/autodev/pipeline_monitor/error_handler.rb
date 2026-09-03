# frozen_string_literal: true

class PipelineMonitor
  # Error recovery for pipeline evaluation/fix failures.
  module ErrorHandler
    private

    def handle_rate_limit(issue, error)
      wait = error.wait_seconds
      retry_at = wait.to_i.seconds.from_now
      log_error "Issue ##{issue.issue_iid}: rate limit hit, parking for #{wait}s"
      safe_mark_failed!(issue, next_retry_at: retry_at)
      Issue.where(id: issue.id).update_all(
        error_message: error.message, dc_stdout: @dc_stdout, dc_stderr: @dc_stderr
      )
      log_activity(issue, :rate_limit, wait: wait)
    end

    # Claude credentials are dead — see IssueProcessor::ErrorHandler#handle_auth_failure.
    # No retry is scheduled and no per-ticket comment is posted. `next_retry_at: nil`
    # is explicit (Autodev #103): retrying against dead credentials cannot produce
    # anything, and a stamp left over from a previous life in `error` must not
    # survive into this one — that is what made 15888 come back on its own, by
    # luck, off a residue from May.
    def handle_auth_failure(issue, error)
      log_error "Issue ##{issue.issue_iid}: Claude authentication failed, manual intervention required"
      safe_mark_failed!(issue, next_retry_at: nil)
      Issue.where(id: issue.id).update_all(
        error_message: "#{error.class}: #{error.message}",
        dc_stdout: @dc_stdout, dc_stderr: @dc_stderr
      )
      log_activity(issue, :auth_failure)
    end

    # The review path's answer to the two typed failures `check_dc_failures!` raises
    # from inside `danger_claude_prompt` (Autodev #74). Same dispatch shape as
    # `handle_failure_error` below, minus the generic arm: a `StandardError` out of
    # a review is already `false` (a counted review failure), so only these two need
    # sorting, and `launch_review` must not let either escape — the row is in
    # `reviewing` by then, which no dispatch pass selects.
    def handle_review_interruption(issue, error)
      return handle_auth_failure(issue, error) if error.is_a?(AuthenticationError)

      handle_rate_limit(issue, error)
    end

    def handle_failure_error(issue, error)
      return handle_auth_failure(issue, error) if error.is_a?(AuthenticationError)

      bt = error.backtrace&.first(10)&.join("\n  ")
      log_error "Pipeline evaluation/fix failed: #{error.class}: #{error.message}"
      log_error "  #{bt}" if bt
      # No retry scheduled — the asymmetry with IssueProcessor's backoff is a
      # policy question left open (see the design doc's Out of scope), but the
      # row must not be stranded: DormantAudit's error arm recovers it (Autodev
      # #103).
      safe_mark_failed!(issue, next_retry_at: nil)
      persist_and_notify_failure(issue, error, bt)
    end

    def persist_and_notify_failure(issue, error, backtrace)
      issue.update(error_message: "Pipeline fix error: #{error.class}: #{error.message}\n  #{backtrace}",
                   dc_stdout: @dc_stdout, dc_stderr: @dc_stderr)
      summary = "#{error.class}: #{error.message[0, 200]}"
      notify_localized(issue.issue_iid, :pipeline_fix_error, error: summary)
      log_activity(issue, :error, error: summary)
    end
  end
end

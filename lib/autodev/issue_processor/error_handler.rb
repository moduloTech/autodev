# frozen_string_literal: true

class IssueProcessor
  # Error recovery for issue processing failures.
  module ErrorHandler
    private

    def handle_rate_limit(issue, error)
      wait = error.wait_seconds
      log_error "Issue ##{issue.issue_iid}: rate limit hit, parking for #{wait}s"
      safe_mark_failed!(issue)
      Issue.where(id: issue.id).update_all(
        error_message: error.message, dc_stdout: @dc_stdout, dc_stderr: @dc_stderr,
        next_retry_at: wait.to_i.seconds.from_now,
        finished_at: Time.current
      )
      log_activity(issue, :rate_limit, wait: wait)
    end

    # Claude credentials are dead — retrying won't help until an operator fixes
    # them, so no next_retry_at is set and no per-ticket error comment is posted
    # (this is an ops problem, not the requester's). The dashboard renders a
    # dedicated message keyed off the AuthenticationError class in error_message.
    def handle_auth_failure(issue, error)
      log_error "Issue ##{issue.issue_iid}: Claude authentication failed, manual intervention required"
      safe_mark_failed!(issue)
      Issue.where(id: issue.id).update_all(
        error_message: "#{error.class}: #{error.message}",
        dc_stdout: @dc_stdout, dc_stderr: @dc_stderr, finished_at: Time.current
      )
      log_activity(issue, :auth_failure)
    end

    def handle_process_error(issue, error)
      return handle_auth_failure(issue, error) if error.is_a?(AuthenticationError)

      bt = error.backtrace&.first(10)&.join("\n  ")
      safe_mark_failed!(issue)
      fields = build_error_fields(issue, error, bt)
      log_retry_info(issue, fields, error)
      Issue.where(id: issue.id).update_all(**fields)
      notify_error_with_activity(issue, error)
      log_error "  #{bt}" if bt
    end

    def notify_error_with_activity(issue, error)
      summary = "#{error.class}: #{error.message[0, 200]}"
      notify_localized(issue.issue_iid, :error_generic, error: summary)
      log_activity(issue, :error, error: summary)
    end

    def build_error_fields(issue, error, backtrace)
      retry_count = (issue.retry_count || 0) + 1
      max = max_retries_config
      backoff_s = retry_backoff_config * (2**(retry_count - 1))

      fields = { error_message: "#{error.class}: #{error.message}\n  #{backtrace}",
                 dc_stdout: @dc_stdout, dc_stderr: @dc_stderr,
                 retry_count: retry_count, finished_at: Time.current }
      # `<=`, not `<`: max_retries counts retries, so a budget of N still owes
      # a retry to the Nth failure (see Config.max_retries). With the strict
      # comparison and the default budget of 1, the very first failure left
      # this NULL and nothing ever re-enqueued the row (Autodev #34).
      fields[:next_retry_at] = backoff_s.seconds.from_now if retry_count <= max
      fields
    end

    def log_retry_info(issue, fields, error)
      max = max_retries_config
      status = fields[:next_retry_at] ? 'will retry' : 'no more retries'
      log_error "Issue ##{issue.issue_iid} failed (#{fields[:retry_count]}/#{max}, #{status}): " \
                "#{error.class}: #{error.message}"
    end

    def max_retries_config = ::Config.max_retries(@project_config, @config)
    def retry_backoff_config = (@project_config['retry_backoff'] || @config['retry_backoff'] || 30).to_i
  end
end

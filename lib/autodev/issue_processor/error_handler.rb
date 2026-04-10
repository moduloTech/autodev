# frozen_string_literal: true

class IssueProcessor
  # Error recovery for issue processing failures.
  module ErrorHandler
    private

    def handle_rate_limit(issue, error)
      wait = error.wait_seconds
      log_error "Issue ##{issue.issue_iid}: rate limit hit, parking for #{wait}s"
      safe_mark_failed!(issue)
      Issue.where(id: issue.id).update(
        error_message: error.message, dc_stdout: @dc_stdout, dc_stderr: @dc_stderr,
        next_retry_at: Sequel.lit("datetime('now', '+#{wait} seconds')"),
        finished_at: Sequel.lit("datetime('now')")
      )
      log_activity(issue, :rate_limit, wait: wait)
    end

    def handle_process_error(issue, error)
      bt = error.backtrace&.first(10)&.join("\n  ")
      safe_mark_failed!(issue)
      fields = build_error_fields(issue, error, bt)
      log_retry_info(issue, fields, error)
      Issue.where(id: issue.id).update(**fields)
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
                 retry_count: retry_count, finished_at: Sequel.lit("datetime('now')") }
      fields[:next_retry_at] = Sequel.lit("datetime('now', '+#{backoff_s} seconds')") if retry_count < max
      fields
    end

    def log_retry_info(issue, fields, error)
      max = max_retries_config
      status = fields[:next_retry_at] ? 'will retry' : 'no more retries'
      log_error "Issue ##{issue.issue_iid} failed (#{fields[:retry_count]}/#{max}, #{status}): " \
                "#{error.class}: #{error.message}"
    end

    def max_retries_config = (@project_config['max_retries'] || @config['max_retries'] || 3).to_i
    def retry_backoff_config = (@project_config['retry_backoff'] || @config['retry_backoff'] || 30).to_i
  end
end

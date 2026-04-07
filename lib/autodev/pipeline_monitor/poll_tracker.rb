# frozen_string_literal: true

class PipelineMonitor
  # Tracks pipeline polling to compact repeated "checking" lines in the activity log.
  # Instead of one line per poll cycle, updates the existing line with the since timestamp.
  module PollTracker
    # Regex matching an activity_pipeline_checking line (any locale).
    POLL_LINE_PATTERN = /— :mag:.*(?:pipeline|statut du pipeline)/

    private

    def log_pipeline_poll(issue)
      now = Time.now.utc.strftime('%H:%M')
      since = issue.pipeline_poll_since || now
      issue.update(pipeline_poll_since: since) unless issue.pipeline_poll_since
      log_activity(issue, :pipeline_checking, since: since, replace_pattern: POLL_LINE_PATTERN)
    end

    def clear_pipeline_poll_since(issue)
      issue.update(pipeline_poll_since: nil) if issue.pipeline_poll_since
    end
  end
end

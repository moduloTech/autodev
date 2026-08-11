# frozen_string_literal: true

class PipelineMonitor
  # Tracks pipeline polling to compact repeated "checking" lines in the activity log.
  # Instead of one line per poll cycle, updates the existing line with the since timestamp.
  module PollTracker
    # Regex matching an activity_pipeline_checking line (any locale).
    POLL_LINE_PATTERN = /— :mag:.*(?:pipeline|statut du pipeline)/

    private

    def log_pipeline_poll(issue)
      now = Time.now.strftime('%m-%d %H:%M')
      since = issue.pipeline_poll_since || now
      issue.update(pipeline_poll_since: since) unless issue.pipeline_poll_since
      seed_watch_clock(issue)
      log_activity(issue, :pipeline_checking, since: since, replace_pattern: POLL_LINE_PATTERN)
    end

    # `Issue#stamp_pipeline_watch!` writes `checking_pipeline_since` on every
    # AASM transition, but two writers set this status with `update_all` and
    # bypass the machine entirely: `Issue.reset_for_retry!` and
    # `Issue.revive_stalled!` (reached from `recover_on_startup!` and
    # `DormantAudit#revive`). They leave the column NULL, so the age bound would
    # never fire on a row that arrived that way. Seeding it here starts the
    # clock at the first poll after the arrival — the closest instant we can
    # observe (Autodev #53).
    def seed_watch_clock(issue)
      issue.update(checking_pipeline_since: Time.current) unless issue.checking_pipeline_since
    end

    def clear_pipeline_poll_since(issue)
      issue.update(pipeline_poll_since: nil) if issue.pipeline_poll_since
    end
  end
end

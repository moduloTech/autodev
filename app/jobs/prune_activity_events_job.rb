# frozen_string_literal: true

# Daily housekeeping: bounds `activity_events` growth via
# Autodev::ActivityEventJanitor, which drops the machinery rows (poller / usage
# / error / heartbeat) past a retention window derived from
# HealthReport#stuck_active_after (Autodev #57). Scheduled in
# config/recurring.yml (production only), like LogJanitorJob and
# ReapFailedJobsJob. Best-effort — a janitor failure must never take the worker
# down, and the next run picks up whatever this one left.
class PruneActivityEventsJob < ApplicationJob
  queue_as :default

  def perform
    result = ::Autodev::ActivityEventJanitor.run
    logger.info("[prune_activity_events] deleted=#{result[:deleted]} " \
                "retention=#{result[:retention_seconds]}s cutoff=#{result[:cutoff].utc.iso8601}")
  rescue StandardError => e
    logger.warn("[prune_activity_events] #{e.class}: #{e.message}")
  end
end

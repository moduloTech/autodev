# frozen_string_literal: true

# Hourly housekeeping: discards the transient process-lifecycle failures
# (worker pruned / exited) that Solid Queue records when the box sleeps or the
# supervisor restarts, so they don't pile up in the "Failed" tab. Real
# application failures are left untouched. Scheduled in config/recurring.yml
# (production only). Best-effort — never takes the worker down.
class ReapFailedJobsJob < ApplicationJob
  queue_as :default

  def perform
    discarded = ::Autodev::FailedJobReaper.run
    logger.info("[reap_failed_jobs] discarded=#{discarded}") if discarded.positive?
  rescue StandardError => e
    logger.warn("[reap_failed_jobs] #{e.class}: #{e.message}")
  end
end

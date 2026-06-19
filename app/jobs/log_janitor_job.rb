# frozen_string_literal: true

# Daily housekeeping: bounds log growth via Autodev::LogJanitor (prunes old
# JSONL + rotation archives, copy-truncates the oversized Rails / supervisor
# logs). Scheduled in config/recurring.yml (production only). Best-effort —
# a janitor failure must never take the worker down.
class LogJanitorJob < ApplicationJob
  queue_as :default

  def perform
    result = ::Autodev::LogJanitor.run
    logger.info("[log_janitor] rotated=#{result[:rotated].size} pruned=#{result[:pruned]}")
  rescue StandardError => e
    logger.warn("[log_janitor] #{e.class}: #{e.message}")
  end
end

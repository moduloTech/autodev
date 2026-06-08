# frozen_string_literal: true

# Recurring entry point that replaces `Poller#poll_loop`. Scheduled in
# config/recurring.yml; Solid Queue fires it every AUTODEV_POLL_INTERVAL
# seconds (default 300, mirroring the legacy `poll_interval`).
#
# Per coexistence phase C of the railsification (cf. docs/autospec.md §D),
# this job lands as part of step 5 but stays dormant in production: bin/autodev
# still drives the threaded poller. The supervisor (step 6) flips the switch
# by starting `solid_queue:start` instead of `bin/autodev`'s own thread loop.
class AutodevPollJob < ApplicationJob
  queue_as :default

  def perform
    config = ::Config.load
    if usage_paused?(config)
      logger.info('[autodev_poll] usage limit hit, skipping cycle')
      return
    end

    Array(config['projects']).each do |project_config|
      ::Autodev::PollDispatcher.new(config: config, project_config: project_config,
                                    logger: logger).dispatch
    end
  end

  private

  # Mirrors `UsageChecker#available?` from the legacy poller. The job
  # backend can't pause a recurring task at the queue layer, so we no-op
  # the cycle if claude's usage budget is exhausted.
  def usage_paused?(_config)
    !::UsageChecker.new(logger: logger).available?
  rescue StandardError => e
    logger.warn("[autodev_poll] usage check failed, assuming available: #{e.class}: #{e.message}")
    false
  end
end

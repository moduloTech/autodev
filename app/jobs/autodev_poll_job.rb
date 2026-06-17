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
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    if usage_paused?(config)
      logger.info('[autodev_poll] usage limit hit, skipping cycle')
      return record_heartbeat(usage_ok: false, projects: 0, started: started, level: 'warn')
    end

    record_heartbeat(usage_ok: true, projects: run_cycle(config), started: started)
  rescue StandardError => e
    record_cycle_error(e)
    raise
  end

  private

  # Runs one dispatch pass over every configured project; returns the count.
  def run_cycle(config)
    projects = Array(config['projects'])
    wrapped_logger = ::Autodev::JobLogger.new(logger)
    projects.each do |project_config|
      ::Autodev::PollDispatcher.new(config: config, project_config: project_config,
                                    logger: wrapped_logger).dispatch
    end
    projects.size
  end

  # Poller liveness heartbeat — the dashboard health surface (Autodev::HealthReport)
  # reads the latest `kind: 'poller'` event to answer "is the poller still ticking?".
  # issue_id is nil (system event): such events are deliberately not broadcast to the
  # SSE feed nor counted in the activity sparkline (see ActivityEvent#broadcast_to_event_bus
  # and Web::Helpers#weekly_activity_counts). Fire-and-forget: never let it break a cycle.
  def record_heartbeat(usage_ok:, projects:, started:, level: 'info')
    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    ActivityEvent.create(
      issue_id: nil, kind: 'poller', level: level,
      payload_json: JSON.generate(event: 'cycle_complete', usage_ok: usage_ok,
                                  projects: projects, duration_ms: duration_ms)
    )
  rescue StandardError => e
    logger.warn("[autodev_poll] heartbeat record failed: #{e.class}: #{e.message}")
  end

  # Cycle-level failure marker (distinct from per-issue errors, which PollDispatcher
  # already rescues per project). Surfaced on the health page; the raise still lets
  # Solid Queue record the failure in solid_queue_failed_executions.
  def record_cycle_error(error)
    ActivityEvent.create(
      issue_id: nil, kind: 'error', level: 'error',
      payload_json: JSON.generate(event: 'cycle_failed', error: "#{error.class}: #{error.message}",
                                  backtrace: Array(error.backtrace).first(5))
    )
  rescue StandardError => e
    logger.warn("[autodev_poll] error record failed: #{e.class}: #{e.message}")
  end

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

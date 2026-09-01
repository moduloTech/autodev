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
    usage_ok = probe_usage

    projects = run_cycle(config, usage_ok: usage_ok)
    record_heartbeat(usage_ok: usage_ok, projects: projects, started: started,
                     level: usage_ok ? 'info' : 'warn')
  rescue StandardError => e
    record_cycle_error(e)
    raise
  end

  private

  # One probe per cycle, persisted by the gate so every worker and the dashboard
  # read the same verdict without shelling out to danger-claude themselves.
  def probe_usage
    usage_ok = ::Autodev::UsageGate.probe!(logger: logger)
    unless usage_ok
      logger.info('[autodev_poll] usage limit hit: implementation paused, ' \
                  'observation passes still running')
    end
    usage_ok
  end

  # Runs one dispatch pass over every project; returns the count. Projects are
  # discovered from the DB (`Project.runtime_configs`, task #9 phase 4), with
  # any not-yet-imported YAML `projects:` entry still picked up as a fallback.
  #
  # `usage_ok` is the cycle's single Claude-quota probe. It used to abort the
  # whole cycle here; since Autodev #46 it travels down to the dispatcher, which
  # skips only the passes that reach danger-claude (see
  # Autodev::PollDispatcher#claude_available?).
  def run_cycle(config, usage_ok:)
    projects = ::Project.runtime_configs(config['projects'])
    wrapped_logger = ::Autodev::JobLogger.new(logger)
    probe_review_skills(config, projects)
    probe_mr_review_token(config, projects)
    projects.each do |project_config|
      ::Autodev::PollDispatcher.new(config: config, project_config: project_config,
                                    logger: wrapped_logger, usage_ok: usage_ok).dispatch
    end
    projects.size
  end

  # One review-skill check per cycle, recorded for the health card to read
  # (Autodev #81). Same shape and same reason as the quota probe above:
  # `HealthReport` is passive by contract, so the live read has to happen here.
  #
  # It costs one GitLab request per project that declares a `review_skill` — the
  # repository-files endpoint answers "is this path on this ref" without a clone
  # — and it is the only thing that can name a misconfigured skill *before* the
  # project's next request stops at the review step. Advisory, so it never breaks
  # a cycle: the probe rescues internally and this guards the call itself, the
  # same ruling `bin/autodev`'s `warn_rejected_numeric_settings` carries.
  def probe_review_skills(config, projects)
    ::Autodev::ReviewSkillProbe.probe!(config: config, projects: projects, logger: logger)
  rescue StandardError => e
    logger.warn("[autodev_poll] review-skill probe failed: #{e.class}: #{e.message}")
  end

  # One check per cycle on the credential the `mr-review` binary runs with
  # (Autodev #80), recorded for the health card to read. Same shape and same
  # reason as the two probes above.
  #
  # It costs *nothing at all* while every project declares a `review_skill`: the
  # probe filters the population first and returns before it asks GitLab, reads a
  # file or writes a row. It arms itself on the first project onboarded without
  # one — the moment a revoked credential starts breaking reviews again, which is
  # what went unnoticed from April to August 2026. Advisory, so it never breaks a
  # cycle: the probe rescues internally and this guards the call itself.
  def probe_mr_review_token(config, projects)
    ::Autodev::MrReviewTokenProbe.probe!(config: config, projects: projects, logger: logger)
  rescue StandardError => e
    logger.warn("[autodev_poll] mr-review token probe failed: #{e.class}: #{e.message}")
  end

  # Poller liveness heartbeat — the dashboard health surface (Autodev::HealthReport)
  # reads the latest `kind: 'poller'` event to answer "is the poller still ticking?".
  # issue_id is nil (system event): such events are deliberately not broadcast to the
  # SSE feed nor counted in the activity sparkline (see ActivityEvent#broadcast_to_event_bus
  # and ActivityEvent.user_visible). Both `poller` and `error` are machinery kinds, so
  # they are also dropped past the retention window (Autodev #57) — only the newest row
  # is ever read. Fire-and-forget: never let it break a cycle.
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
end

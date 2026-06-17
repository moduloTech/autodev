# frozen_string_literal: true

module Autodev
  # Passive system-health snapshot — the single source of truth behind both the
  # /healthz monitoring endpoints (MonitoringController) and the /admin/health
  # page (Web::Views::Admin::Health).
  #
  # "Passive" means it only reads state already recorded (poller heartbeats,
  # Solid Queue rows, issue statuses) — it never shells out to danger-claude or
  # calls GitLab, so it's instant and safe to hammer from an external probe.
  #
  # #call returns:
  #   { status: :ok|:warn|:down, generated_at: <iso8601>,
  #     checks: { <name> => { status:, detail:, meta: {} }, ... } }
  # where the top-level status is the worst severity across checks.
  class HealthReport # rubocop:disable Metrics/ClassLength
    CHECKS = %i[poller workers queue claude_usage issues_error database].freeze
    SEVERITY = { ok: 0, warn: 1, down: 2 }.freeze

    DEFAULT_POLL_INTERVAL = 300
    DEFAULT_POLL_STALE_FACTOR = 3
    POLL_STALE_FLOOR = 900 # never flag stale before 15 min, even on a tight interval
    BACKLOG_WARN = 100

    # poller_expected: whether the recurring poll is supposed to be running here.
    # Defaults to "not a local env" — config/recurring.yml disables recurring
    # jobs in development, so a missing heartbeat there is normal, not a fault.
    def initialize(config: nil, now: Time.current, poller_expected: !Rails.env.local?)
      @config = config || (defined?(::Web) && ::Web.config) || {}
      @now = now
      @poller_expected = poller_expected
    end

    def self.call(**) = new(**).call

    def call
      results = CHECKS.to_h { |name| [name, safe_check(name)] }
      { status: rollup(results.values), generated_at: iso(@now), checks: results }
    end

    # One named component, same envelope shape as #call (status reflects it).
    def check(name)
      name = name.to_sym
      raise ArgumentError, "unknown check: #{name}" unless CHECKS.include?(name)

      one = safe_check(name)
      { status: one[:status], generated_at: iso(@now), checks: { name => one } }
    end

    private

    def safe_check(name)
      send("check_#{name}")
    rescue StandardError => e
      build(:down, "check raised #{e.class}: #{e.message}")
    end

    # --- individual checks -------------------------------------------------

    def check_poller
      last = last_poller_event
      return poller_present(last) if last
      return build(:ok, 'poller disabled in this environment') unless @poller_expected

      build(:down, 'no poll cycle ever recorded')
    end

    def poller_present(last)
      age = (@now - last.created_at).round
      meta = { last_poll_at: iso(last.created_at), age_seconds: age, stale_after_seconds: poll_stale_after }
      return build(:down, "last poll #{age}s ago (stale after #{poll_stale_after}s)", meta) if age > poll_stale_after

      build(:ok, "last poll #{age}s ago", meta)
    end

    def check_workers
      cutoff = @now - SolidQueue.process_alive_threshold
      alive = SolidQueue::Process.where(last_heartbeat_at: cutoff..)
      total = alive.count
      workers = alive.where(kind: 'Worker').count
      meta = { workers: workers, processes: total }
      return build(:down, 'no Solid Queue process alive', meta) if total.zero?
      return build(:down, 'no worker process alive', meta) if workers.zero?

      build(:ok, "#{workers} worker(s) alive", meta)
    end

    def check_queue
      failed = SolidQueue::FailedExecution.count
      pending = SolidQueue::ReadyExecution.count + SolidQueue::ScheduledExecution.count
      meta = { failed: failed, pending: pending }
      return build(:warn, "#{failed} failed job(s)", meta) if failed.positive?
      return build(:warn, "#{pending} jobs backed up", meta) if pending > BACKLOG_WARN

      build(:ok, "#{pending} pending, no failures", meta)
    end

    # Passive read of the last poll's usage flag — no live probe.
    def check_claude_usage
      last = last_poller_event
      return build(:ok, 'no poll data yet') if last.nil?

      if last.payload['usage_ok'] == false
        build(:warn, 'Claude usage exhausted at last poll', checked_at: iso(last.created_at))
      else
        build(:ok, 'Claude usage available at last poll', checked_at: iso(last.created_at))
      end
    end

    def check_issues_error
      count = Issue.where("status = 'error' OR post_completion_error IS NOT NULL").count
      meta = { count: count }
      return build(:warn, "#{count} issue(s) in error", meta) if count.positive?

      build(:ok, 'no issues in error', meta)
    end

    def check_database
      ActiveRecord::Base.connection.execute('SELECT 1')
      SolidQueue::Job.connection.execute('SELECT 1')
      build(:ok, 'primary + queue reachable')
    end

    # --- helpers -----------------------------------------------------------

    def last_poller_event
      unless defined?(@last_poller_event)
        @last_poller_event = ActivityEvent.where(kind: 'poller').order(created_at: :desc).first
      end
      @last_poller_event
    end

    def poll_stale_after
      @poll_stale_after ||= [(poll_interval * poll_stale_factor), POLL_STALE_FLOOR].max
    end

    def poll_interval
      (@config['poll_interval'] || DEFAULT_POLL_INTERVAL).to_i
    end

    def poll_stale_factor
      (@config.dig('monitoring', 'poll_stale_factor') || DEFAULT_POLL_STALE_FACTOR).to_i
    end

    def build(status, detail, meta = {})
      { status: status, detail: detail, meta: meta }
    end

    def rollup(checks)
      checks.map { |c| c[:status] }.max_by { |s| SEVERITY.fetch(s, 0) } || :ok
    end

    def iso(time)
      time.utc.iso8601
    end
  end
end

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
    CHECKS = %i[poller workers queue claude_usage issues_error stuck_issues database].freeze
    SEVERITY = { ok: 0, warn: 1, down: 2 }.freeze

    DEFAULT_POLL_INTERVAL = 300
    DEFAULT_POLL_STALE_FACTOR = 3
    POLL_STALE_FLOOR = 900 # never flag stale before 15 min, even on a tight interval
    BACKLOG_WARN = 100

    # "Stuck" detection — the invariant that a green dashboard must not hide:
    # every issue in a non-terminal, non-human-wait state has *some* dispatcher
    # pass that will advance it, so it must keep producing activity. A row that
    # sits in such a state with no recent activity has, de facto, no path
    # forward (e.g. a `pending` row reset on startup whose GitLab label drifted
    # off `labels_todo`, so neither dispatch_new_issues nor dispatch_retries
    # picks it up). `pending` should leave within a poll cycle, so it reuses the
    # poller-staleness window; the active workflow states tolerate long
    # danger-claude runs (which still emit activity), so they get a wider one.
    # Excluded by design: done/closed (terminal), error (own panel + backoff),
    # needs_clarification (waits on a human), checking_pipeline (waits on an
    # external pipeline, re-polled every cycle — the documented "no blocked
    # state").
    PENDING_STUCK_STATES = %w[pending].freeze
    # The states a stalled row can be revived out of — the same set
    # `Issue.revive_stalled!` knows the rules for, by construction. A state this
    # card flags but nothing can revive would be a card nobody can act on.
    ACTIVE_STUCK_STATES = ::Issue::STALLED_STATES
    STUCK_ACTIVE_AFTER = 7200 # 2h with zero activity ⇒ a dead worker, not a long run

    # A live worker's silence is bounded by one danger-claude call — the
    # DangerClaudeRunner heartbeat (Autodev #50) writes an activity row per call,
    # so no loop can go quiet for longer than its own timeout. The window only
    # has to clear that timeout; twice over, for loop overhead and margin.
    HEARTBEAT_FACTOR = 2

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

    # Public because Autodev::DormantAudit reads both windows too: the
    # stuck-issues card and the dormant-rows pass must see the same rows, or
    # the card keeps flagging what nothing recovers (Autodev #47).
    def poll_stale_after
      @poll_stale_after ||= [(poll_interval * poll_stale_factor), POLL_STALE_FLOOR].max
    end

    # Derived, not just configured (Autodev #50). DormantAudit#active_window
    # reads this too and repositions rows by update_all, outside the
    # concurrency lock that serialises IssueProcessJob — so a window narrower
    # than the longest configured timeout does not merely mis-report, it lets
    # the audit mutate a row a live worker still holds. Deriving it means the
    # two settings can no longer be configured into disagreement.
    def stuck_active_after
      @stuck_active_after ||= [configured_stuck_active_after,
                               HEARTBEAT_FACTOR * longest_worker_timeout].max
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

    # Passive read of Autodev::UsageGate's persisted verdict — no live probe.
    # The gate is written when the cycle probes (before any pass runs), so it is
    # fresher than the end-of-cycle heartbeat this used to read, and it is the
    # very state the dispatcher and PipelineMonitor act on (Autodev #46). It
    # fails open on a missing or stale verdict; a poller that stopped ticking is
    # the `poller` check's job to report, not this one's.
    def check_claude_usage
      state = UsageGate.state(config: @config, now: @now)
      return build(:ok, 'no usage probe on file') if state[:checked_at].nil?

      meta = { checked_at: iso(state[:checked_at]) }
      return build(:warn, 'Claude usage exhausted at last probe', meta) unless state[:available]

      build(:ok, 'Claude usage available at last probe', meta)
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

    def check_stuck_issues
      stuck = stuck_issues
      # window_seconds so the effective value is visible: it is derived, so a
      # narrower `monitoring.stuck_active_after_seconds` does not apply.
      meta = { count: stuck.size, window_seconds: stuck_active_after }
      return build(:ok, 'no stuck issues', meta) if stuck.empty?

      meta[:sample] = stuck.first(5).map { |i| "##{i.issue_iid}(#{i.status})" }.join(' ')
      build(:warn, "#{stuck.size} issue(s) stuck with no path forward", meta)
    end

    # --- helpers -----------------------------------------------------------

    # Two windows, one definition of dormancy (Issue.without_activity_since,
    # Autodev #47). `pending` should leave within a poll cycle so it reuses the
    # poller-staleness window; the active workflow states tolerate long
    # danger-claude runs, which still emit activity, so they get a wider one.
    def stuck_issues
      Issue.where(status: PENDING_STUCK_STATES).without_activity_since(@now - poll_stale_after).to_a +
        Issue.where(status: ACTIVE_STUCK_STATES).without_activity_since(@now - stuck_active_after).to_a
    end

    def last_poller_event
      unless defined?(@last_poller_event)
        @last_poller_event = ActivityEvent.where(kind: 'poller').order(created_at: :desc).first
      end
      @last_poller_event
    end

    def poll_interval
      (@config['poll_interval'] || DEFAULT_POLL_INTERVAL).to_i
    end

    def poll_stale_factor
      (@config.dig('monitoring', 'poll_stale_factor') || DEFAULT_POLL_STALE_FACTOR).to_i
    end

    def configured_stuck_active_after
      (@config.dig('monitoring', 'stuck_active_after_seconds') || STUCK_ACTIVE_AFTER).to_i
    end

    # The longest a worker can legitimately go quiet: one danger-claude call
    # (dc_timeout) or one post_completion command (post_completion_timeout —
    # not a danger-claude call, so it gets no heartbeat and its silence equals
    # its timeout exactly). Both are per-project only, so the window is sized on
    # the widest value in play. The baked defaults are always in the max: a
    # project that overrides neither still runs with them.
    def longest_worker_timeout
      [::Config::DEFAULTS['dc_timeout'], ::Config::POST_COMPLETION_TIMEOUT,
       Project.maximum(:dc_timeout), Project.maximum(:post_completion_timeout),
       *yaml_project_timeouts].compact.map(&:to_i).max
    end

    # Projects configured in config.yml but not yet imported into the projects
    # table: still live config, since IssueProcessJob falls back to the YAML hash
    # for a project with no row.
    def yaml_project_timeouts
      Array(@config['projects']).flat_map do |project|
        next [] unless project.is_a?(Hash)

        [project['dc_timeout'], project['post_completion_timeout']]
      end
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

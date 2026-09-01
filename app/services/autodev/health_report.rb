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
    CHECKS = %i[poller workers queue claude_usage issues_error mr_review review_skill
                mr_review_token stuck_issues database migrations].freeze
    SEVERITY = { ok: 0, warn: 1, down: 2 }.freeze

    DEFAULT_POLL_INTERVAL = 300
    DEFAULT_POLL_STALE_FACTOR = 3
    POLL_STALE_FLOOR = 900 # never flag stale before 15 min, even on a tight interval
    BACKLOG_WARN = 100

    # "the review is broken for everybody" detection (Autodev #60, item 1) — the
    # alert missing behind Autodev #49. `review_failure_count` is per ticket and
    # `review_failures_exhausted` raises a per-ticket `needs_attention` flag, so a
    # tool-wide outage produced N unrelated flags and nothing saying the tool was
    # dead. Nobody correlates three isolated tickets: the real incident ran for
    # weeks and three MRs shipped unreviewed.
    #
    # The two activity keys every review failure is recorded under, on either
    # path (Autodev #74) —
    # `review_failed` per attempt (Reviewer#finalize_review_failure) and
    # `review_failures_exhausted` on the last one (Reviewer#give_up_reviewing).
    REVIEW_FAILURE_KEYS = %w[review_failed review_failures_exhausted].freeze

    # Calibrated on the 12/08/2026 production copy, not guessed. Rolling 6h
    # windows over 4.5 months of activity_events (142 issues, 882k rows):
    #
    #   * six isolated single-ticket incidents (01/07, 02/07, 30/07, 06/08,
    #     07/08, 12/08). Each is one ticket burning its five attempts inside ten
    #     minutes: **max 1 distinct issue** in any 6h window, max 6 events;
    #   * the tool-wide outage of 11/08 between 14:00 and 23:59: **25 distinct
    #     issues** in a 6h window, 489 events.
    #
    # So the populations do not overlap at all, and 3 distinct issues sits with
    # margin above the observed noise floor of 1. Replaying the outage against
    # this threshold fires at 14:05:28 — five minutes after the first failure,
    # against the weeks it actually took.
    #
    # Counted in *distinct issues*, deliberately, not events: Autodev #61's replay
    # bug put 26 identical give-up comments on a single ticket, and an event count
    # would have been inflated by something that says nothing about the review.
    DEFAULT_REVIEW_FAILURE_WINDOW = 21_600 # 6h
    DEFAULT_REVIEW_FAILURE_THRESHOLD = 3   # distinct issues inside the window

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

    # Heuristic, not a bound, for as long as any inter-call work is untimed. The
    # DangerClaudeRunner heartbeat (Autodev #50) resets the clock when a call
    # starts, so the worst-case gap for a live worker is (heartbeat -> call end:
    # dc_timeout + kill grace + pipe drain) + (call end -> next heartbeat or
    # transition: untimed inter-call work — screenshot uploads, job_trace
    # fetches, git operations, the clone_and_checkout inside post_completion).
    # This factor pays for the second term; it multiplies a timeout, not a
    # heartbeat interval, hence the name.
    TIMEOUT_SLACK_FACTOR = 2

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
                               TIMEOUT_SLACK_FACTOR * longest_worker_timeout].max
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

    # `warn`, not `down`: a broken review does not stop delivery, so the uptime
    # probe must keep seeing 200 while the JSON body carries the warn for a
    # secondary alert. Same tier as "issues in error".
    def check_mr_review
      count = review_failure_issue_count
      meta = { issues: count, window_seconds: review_failure_window,
               threshold: review_failure_threshold }
      if count >= review_failure_threshold
        return build(:warn, "the review failed on #{count} issue(s) in the last " \
                            "#{review_failure_window}s — the tool may be broken for everybody", meta)
      end

      build(:ok, "review failures on #{count} issue(s)", meta)
    end

    # A project declaring a `review_skill` its repository does not carry stops
    # every one of its requests at the review step (Autodev #81). Passive like
    # everything else here: the poll cycle runs the live check
    # (Autodev::ReviewSkillProbe) and this reads the recorded verdict, exactly as
    # `check_claude_usage` reads UsageGate's.
    #
    # `warn`, not `down`, and the same tier as `mr_review`: the fault is confined
    # to the misconfigured project, so `/healthz` must keep answering 200 while
    # the body carries the warn for a secondary alert.
    #
    # Only `missing` raises it. An `unknown` verdict — GitLab unreachable when the
    # cycle probed — is deliberately absent from what is recorded: telling an
    # operator their configuration is broken because of an outage is the mistake
    # Autodev #62 is about, in another costume.
    def check_review_skill
      state = ReviewSkillProbe.state(config: @config, now: @now)
      return build(:ok, 'no review-skill probe on file') if state[:checked_at].nil?

      review_skill_verdict(state)
    end

    def review_skill_verdict(state)
      missing = state[:missing]
      meta = { checked: state[:checked], missing: missing.size, checked_at: iso(state[:checked_at]) }
      return build(:ok, "#{state[:checked]} declared review skill(s), all present", meta) if missing.empty?

      meta[:sample] = missing.first(5).map { |entry| review_skill_fault(entry) }.join(' ')
      build(:warn, "#{missing.size} project(s) declare a review skill their repository does not carry — " \
                   'every request of those projects stops at the review step', meta)
    end

    def review_skill_fault(entry)
      "#{entry['path']}(#{entry['expected']}@#{entry['ref'] || '?'})"
    end

    # Does GitLab still accept the credential the `mr-review` binary runs with?
    # (Autodev #80.) Passive like everything else here: the poll cycle runs the
    # live check (Autodev::MrReviewTokenProbe) and this reads the recorded
    # verdict, exactly as `check_claude_usage` reads UsageGate's.
    #
    # `warn`, not `down`, and the same tier as `mr_review` and `review_skill`: a
    # review that cannot run does not stop delivery, so `/healthz` keeps
    # answering 200 while the body carries the warn for a secondary alert.
    #
    # Only `revoked` raises it. Nothing on file is the *normal* state — no
    # project reviews through the binary today, so the probe never runs — and an
    # `unknown` is a read that failed, not a verdict on a credential (Autodev
    # #62). Both are `ok`.
    def check_mr_review_token
      state = MrReviewTokenProbe.state(config: @config, now: @now)
      return build(:ok, 'no mr-review credential probe on file') if state[:checked_at].nil?

      meta = { source: state[:source], checked_at: iso(state[:checked_at]) }
      if state[:status] == MrReviewTokenProbe::REVOKED
        return build(:warn, 'GitLab rejected the credential mr-review runs with ' \
                            "(`#{state[:source]}`) — every review on the binary path fails", meta)
      end

      build(:ok, "mr-review credential #{state[:status]} at last probe", meta)
    end

    def check_database
      ActiveRecord::Base.connection.execute('SELECT 1')
      SolidQueue::Job.connection.execute('SELECT 1')
      build(:ok, 'primary + queue reachable')
    end

    # `auto_migrate.rb` runs the migration pass at every boot and swallows its
    # failures by design, so the only trustworthy signal that it worked is the
    # state it left: the migration files minus the `schema_migrations` rows, per
    # database (Autodev #55). `down` rather than `warn` — an incomplete schema is
    # a real outage, not a degraded-but-up condition: `Project#to_project_config`
    # raises `NoMethodError` on a missing column, so every job fails. That puts
    # it in the paging tier next to "no worker alive" and "database unreachable".
    def check_migrations
      pending = MigrationStatus.pending
      return build(:ok, 'schema up to date') if pending.empty?

      meta = pending.transform_keys { |name| :"pending_#{name}" }
                    .transform_values { |versions| versions.join(', ') }
      build(:down, "#{pending.values.sum(&:size)} migration(s) not applied", meta)
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

    # All projects, one query. Bounded by `(kind, created_at)` — the leading
    # columns of `idx_ae_kind` — before the payload is looked at, so the LIKE only
    # ever runs over the window's rows (~1 700 at production's write rate) rather
    # than over the 882k-row table. Do not reorder those clauses away.
    def review_failure_issue_count
      ActivityEvent.where(kind: 'danger_claude')
                   .where.not(issue_id: nil)
                   .where(created_at: (@now - review_failure_window)..)
                   .where(*review_failure_key_clause)
                   .distinct
                   .count(:issue_id)
    end

    # `payload_json` is always produced by `ActivityLogger.payload_for` as
    # `{"key":"<key>",...}`, so a literal JSON prefix is an exact match on the key
    # — no JSON parsing in SQL. The keys are snake_case and `_` is a LIKE
    # wildcard, hence the ESCAPE: without it `review_failed` would also match
    # `reviewXfailed`, and the trailing `",` is what keeps `review_failed` from
    # matching `review_failures_exhausted`.
    def review_failure_key_clause
      sql = Array.new(REVIEW_FAILURE_KEYS.size, 'payload_json LIKE ? ESCAPE ?').join(' OR ')
      args = REVIEW_FAILURE_KEYS.flat_map { |key| ["#{like_escape(%({"key":"#{key}",))}%", '\\'] }
      [sql, *args]
    end

    def like_escape(text) = text.gsub(/[\\%_]/) { |char| "\\#{char}" }

    # Through `NumericSettings.monitoring_integer`, not `.to_i`: a window that
    # read as 0 s made this check answer `:ok` for ever (the query asks for events
    # newer than "now"), and a threshold that read as 0 made it answer `:warn` for
    # ever. Both are the failure mode Autodev #58 exists to end — a typo that
    # silently switches a protection off — so both fall back to the default here
    # and are refused outright at boot by `ConfigValidator`.
    def review_failure_window
      NumericSettings.monitoring_integer(@config, 'review_failure_window_seconds',
                                         default: DEFAULT_REVIEW_FAILURE_WINDOW)
    end

    def review_failure_threshold
      NumericSettings.monitoring_integer(@config, 'review_failure_threshold',
                                         default: DEFAULT_REVIEW_FAILURE_THRESHOLD)
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
      NumericSettings.monitoring_integer(@config, 'poll_stale_factor', default: DEFAULT_POLL_STALE_FACTOR)
    end

    def configured_stuck_active_after
      NumericSettings.monitoring_integer(@config, 'stuck_active_after_seconds', default: STUCK_ACTIVE_AFTER)
    end

    # The longest a worker can legitimately go quiet: one danger-claude call
    # (dc_timeout), one post_completion command (post_completion_timeout — not a
    # danger-claude call, so it gets no heartbeat and its silence equals its
    # timeout exactly), or one mr-review run (mr_review_timeout — also no
    # heartbeat of its own beyond the marker written before the call, Autodev
    # #54). All three are per-project only, so the window is sized on the widest
    # value in play. The baked defaults are always in the max: a project that
    # overrides none of them still runs with them — and 2 × MR_REVIEW_TIMEOUT
    # (3600) is exactly the existing 7200 floor, so adding this term does not
    # move the default window.
    def longest_worker_timeout
      [::Config::DEFAULTS['dc_timeout'], ::Config::POST_COMPLETION_TIMEOUT, ::Config::MR_REVIEW_TIMEOUT,
       Project.maximum(:dc_timeout), Project.maximum(:post_completion_timeout),
       Project.maximum(:mr_review_timeout), *yaml_project_timeouts].compact.map(&:to_i).max
    end

    # Projects configured in config.yml but not yet imported into the projects
    # table: still live config, since IssueProcessJob falls back to the YAML hash
    # for a project with no row.
    def yaml_project_timeouts
      Array(@config['projects']).flat_map do |project|
        next [] unless project.is_a?(Hash)

        [project['dc_timeout'], project['post_completion_timeout'], project['mr_review_timeout']]
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

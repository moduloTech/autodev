# frozen_string_literal: true

module Autodev
  # Shared Claude-quota state (Autodev #46).
  #
  # `UsageChecker` answers "is the Claude quota still there?" by shelling out to
  # `danger-claude`, and it is instantiated per call — its TTL cache never spans
  # two jobs. Probing at every consumption point would therefore mean up to one
  # Docker round-trip per tracked ticket per cycle.
  #
  # So the poll cycle probes ONCE (`probe!`) and persists the verdict as a
  # system `ActivityEvent(kind: 'usage')`; everyone downstream (PollDispatcher,
  # PipelineMonitor, IssueProcessJob, the dashboard) reads that state passively
  # via `available?` / `state`. No new table: `issue_id` is nullable and
  # `ActivityEvent#broadcast_to_event_bus` already skips issue-less rows, so
  # these never reach the SSE feed.
  #
  # KIND is one of `ActivityEvent::MACHINERY_KINDS`, so these rows are invisible
  # to every rendering path and are dropped past the retention window
  # (Autodev::ActivityEventJanitor, Autodev #57). Only the newest verdict is ever
  # read, and it is trusted for two poll intervals — four orders of magnitude
  # inside that window. Do not start reading this kind as a *history*: at 720
  # rows a day it was the single largest remaining source of table growth, and
  # nothing keeps it.
  #
  # Everything fails OPEN — no probe, an unreadable payload, or a verdict older
  # than the TTL all read as "available". A failure to *observe* the quota must
  # never be what stops the pipeline; the worst case is one danger-claude call
  # that fails on its own and takes the usual error path.
  class UsageGate
    KIND = 'usage'

    DEFAULT_POLL_INTERVAL = 300
    # A verdict is trusted for two poll intervals, never less than 10 minutes —
    # the floor keeps a tight interval from expiring the state between the probe
    # and the jobs it gates.
    TTL_POLL_INTERVALS = 2
    TTL_FLOOR = 600
    # Upper bound on how many probes a `consecutive` streak is counted over
    # (alpha-53 review, G5): the debounce it feeds is 2, so anything past a
    # handful is already decided, and this keeps the query bounded.
    STREAK_LIMIT = 20

    # The statuses `UsageChecker#verdict` can answer that close the gate
    # (Autodev #108): a quota outage, a dead credential, an absent binary, or a
    # failure nothing recognised. `available` and `unknown` keep it open — a
    # verdict the probe could not reach is a failure to *observe*, not a fault,
    # and the fail-open doctrine above is precisely about that failure mode.
    CLOSED_STATUSES = %w[quota_exhausted auth_refused binary_missing broken].freeze

    class << self
      # Runs the live probe and records the verdict. Called once per cycle by
      # AutodevPollJob, before any dispatch pass.
      def probe!(logger:)
        verdict = ::UsageChecker.new(logger: logger).verdict
        record(verdict)
        gate_open?(verdict[:status])
      rescue StandardError => e
        logger&.warn("[usage_gate] probe failed, assuming available: #{e.class}: #{e.message}")
        true
      end

      def available?(config: nil, now: Time.current)
        state(config: config, now: now).fetch(:available)
      end

      # { available: Boolean, checked_at: Time|nil, status: Symbol|nil,
      #   diagnostic: String|nil } — `checked_at` is nil when no usable verdict
      # is on file (never probed, unreadable, or stale), which is exactly when
      # `available` is the fail-open default. `status`/`diagnostic` are nil on
      # that default AND on a row written before Autodev #108 (no `status` key
      # in its payload) — reading such a row must not raise, only read as less
      # specific than a fresh one.
      def state(config: nil, now: Time.current)
        event = last_event
        return unknown_state if event.nil? || (now - event.created_at) > ttl(config)

        state_from(event)
      rescue StandardError
        unknown_state
      end

      # How many probes in a row, ending with the most recent one, found
      # `danger-claude` **unhealthy** — what `HealthReport` debounces the
      # `broken` catch-all on rather than paging on one observation.
      #
      # Two things this counts that the first version did not, both found by
      # the second neutral review.
      #
      # It counts a **run of polls**, not a run of rows: a gap wider than the
      # probe's own TTL means probes are missing (the poller was down, the
      # machine was asleep), and two verdicts either side of such a gap are not
      # consecutive. Without that, a `broken` from this morning plus one fresh
      # probe read as a streak of two and paged immediately.
      #
      # And it counts "not healthy" rather than "the same status", because a
      # tool that alternates between failing and hanging produces
      # `broken, unknown, broken, …` and never reached two of anything — while
      # #108 exists because two *total* outages went unseen. `unknown` still
      # reads `ok` on the card on its own (a probe that could not observe is
      # not a fault, Autodev #62); what it may no longer do is break a run.
      def consecutive(status, config: nil, now: Time.current)
        _ = status
        window = ttl(config)
        cutoff = now
        recent_events.take_while do |event|
          in_run = unhealthy?(event) && (cutoff - event.created_at) <= window
          cutoff = event.created_at if in_run
          in_run
        end.size
      rescue StandardError
        1 # unreadable history reads as "the one we just saw", never as a streak
      end

      private

      # Newest first, bounded. `STREAK_LIMIT` is the most probes a streak is
      # ever counted over; anything beyond it is already well past the
      # debounce.
      def recent_events
        ActivityEvent.where(kind: KIND).order(created_at: :desc, id: :desc).limit(STREAK_LIMIT)
      end

      def unhealthy?(event) = event.payload['available'] == false

      def state_from(event)
        value = event.payload['available']
        return unknown_state unless [true, false].include?(value)

        { available: value, checked_at: event.created_at,
          status: event.payload['status']&.to_sym, diagnostic: event.payload['diagnostic'] }
      end

      def gate_open?(status) = !CLOSED_STATUSES.include?(status.to_s)

      def unknown_state = { available: true, checked_at: nil, status: nil, diagnostic: nil }

      def last_event
        ActivityEvent.where(kind: KIND).order(created_at: :desc, id: :desc).first
      end

      def record(verdict)
        status = verdict[:status]
        available = gate_open?(status)
        payload = { available: available, status: status.to_s }
        payload[:diagnostic] = verdict[:diagnostic] if verdict[:diagnostic]
        ActivityEvent.create(
          issue_id: nil, kind: KIND, level: available ? 'info' : 'warn',
          payload_json: JSON.generate(payload)
        )
      rescue StandardError
        nil # fire-and-forget: an unrecordable verdict just means "unknown"
      end

      def ttl(config)
        resolved = config || (defined?(::Web) && ::Web.config) || {}
        interval = (resolved['poll_interval'] || DEFAULT_POLL_INTERVAL).to_i
        [interval * TTL_POLL_INTERVALS, TTL_FLOOR].max
      end
    end
  end
end

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

    class << self
      # Runs the live probe and records the verdict. Called once per cycle by
      # AutodevPollJob, before any dispatch pass.
      def probe!(logger:)
        available = ::UsageChecker.new(logger: logger).available?
        record(available)
        available
      rescue StandardError => e
        logger&.warn("[usage_gate] probe failed, assuming available: #{e.class}: #{e.message}")
        true
      end

      def available?(config: nil, now: Time.current)
        state(config: config, now: now).fetch(:available)
      end

      # { available: Boolean, checked_at: Time|nil } — `checked_at` is nil when
      # no usable verdict is on file (never probed, unreadable, or stale), which
      # is exactly when `available` is the fail-open default.
      def state(config: nil, now: Time.current)
        event = last_event
        return unknown if event.nil? || (now - event.created_at) > ttl(config)

        value = event.payload['available']
        return unknown unless [true, false].include?(value)

        { available: value, checked_at: event.created_at }
      rescue StandardError
        unknown
      end

      private

      def unknown = { available: true, checked_at: nil }

      def last_event
        ActivityEvent.where(kind: KIND).order(created_at: :desc, id: :desc).first
      end

      def record(available)
        ActivityEvent.create(
          issue_id: nil, kind: KIND, level: available ? 'info' : 'warn',
          payload_json: JSON.generate(available: available)
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

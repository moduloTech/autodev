# frozen_string_literal: true

module Autodev
  # Sliding retention on `activity_events` (Autodev #57).
  #
  # Autodev #53 closed the fast leak — one `danger_claude` row per poll per
  # watched ticket, 53 % of the table — and shipped `ActivityEventCompaction` to
  # clear the arrears by hand. Neither bounds growth. Nothing ever deleted a
  # row, and Autodev #50's `heartbeat` kind opened a slower leak in the same
  # family in the same release. What remains after the collapse is almost
  # entirely machinery: on 12/08/2026 production wrote 720 `poller` rows, 720
  # `usage` rows and ~650 `heartbeat` rows against ~50 `danger_claude` and ~20
  # `transition` ones. So the window only needs to cover
  # `ActivityEvent::MACHINERY_KINDS`; the business rows are the audit trail the
  # issue timeline renders, and #53's collapse already bounds them per issue.
  #
  # ## Why the window is derived, not configured
  #
  # `Issue.without_activity_since` deliberately counts heartbeats: a live but
  # quiet worker stays out of `dispatch_dormant_audit`'s population only because
  # its last heartbeat is younger than `HealthReport#stuck_active_after`. The
  # audit mutates by `update_all`, outside the `limits_concurrency` that
  # serialises `IssueProcessJob` — so deleting a heartbeat inside that window
  # does not merely lose a log line, it hands a ticket somebody is working on
  # back to the dispatcher. A retention window fixed independently of that one
  # would break the invariant the first time anybody raised a timeout, exactly
  # as a fixed `stuck_active_after` did before Autodev #50 derived it.
  #
  # Hence `RETENTION_FACTOR × stuck_active_after`, and hence
  # `monitoring.activity_event_retention_seconds` is a **floor**, never a
  # ceiling: you may keep machinery rows longer for forensics, you may not keep
  # them for less time than the safety window.
  #
  # Best-effort by design, like every other writer on this table: run by
  # PruneActivityEventsJob (config/recurring.yml, production only).
  class ActivityEventJanitor
    # A heartbeat answers one question — "is this worker alive *now*" — so its
    # value is gone within hours. 12 × the safety window is 24 h at default
    # settings, which is the roundness worth having: two orders of magnitude
    # more margin than the invariant needs, still a bounded table. It moves with
    # the window, so a project raising `dc_timeout` widens both together.
    RETENTION_FACTOR = 12

    # Matches ActivityEventCompaction: an interrupt costs at most one statement
    # and a re-run picks up where it stopped (the pass is idempotent anyway).
    BATCH_SIZE = 10_000

    def self.run(**) = new(**).run

    def initialize(config: nil, now: Time.current)
      @config = config || (defined?(::Web) && ::Web.config) || {}
      @now = now
    end

    # { deleted: Integer, retention_seconds: Integer, cutoff: Time }
    def run
      scope = purgeable
      deleted = scope.count
      scope.in_batches(of: BATCH_SIZE).delete_all if deleted.positive?
      { deleted: deleted, retention_seconds: retention_seconds, cutoff: cutoff }
    end

    def retention_seconds
      @retention_seconds ||= [configured_retention, RETENTION_FACTOR * safety_window].max
    end

    def cutoff = @now - retention_seconds

    private

    # `delete_all`, so no `destroy` callbacks and no instantiation of ~40 000
    # rows on the first production pass. `created_at` is a TEXT column on the
    # pre-Rails production table (see the model's `attribute` declaration);
    # the serialised 'YYYY-MM-DD HH:MM:SS' form compares lexicographically in
    # the same order as chronologically, which is what every other time-bounded
    # query on this table already relies on.
    def purgeable
      ActivityEvent.where(kind: ActivityEvent::MACHINERY_KINDS).where(created_at: ...cutoff)
    end

    # The bound the whole class is sized against. Read from HealthReport so
    # there is one derivation of it, shared with the stuck-issues card and
    # DormantAudit#active_window.
    def safety_window
      @safety_window ||= HealthReport.new(config: @config, now: @now).stuck_active_after
    end

    # No independent default: absent config, the derived floor *is* the window,
    # which is why `default: 0` is the right fallback here rather than a number of
    # its own. A garbage value lands on the same 0 and is therefore ignored the
    # same way a too-narrow setting is — but it goes through
    # `NumericSettings.monitoring_integer` rather than `.to_i` so it is refused at
    # boot and cannot pass for a deliberate choice.
    def configured_retention
      NumericSettings.monitoring_integer(@config, 'activity_event_retention_seconds', default: 0)
    end
  end
end

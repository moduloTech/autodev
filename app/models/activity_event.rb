# frozen_string_literal: true

# Authoritative ActivityEvent model (railsification step 2 second half).
#
# Replaces the dynamically-built `Sequel::Model(db[:activity_events])` that
# `Database.build_activity_event_model!` used to const_set at boot. The SSE
# fan-out moved from Sequel's `after_create` hook to AR's
# `after_create_commit` so subscribers only see events the DB actually
# accepted (rolled-back transactions no longer leak partial state).
class ActivityEvent < ApplicationRecord
  # `poller`, `error` and `usage` are system events (issue_id nil): heartbeats,
  # cycle-failure markers, and the Claude-quota verdict Autodev::UsageGate
  # persists once per cycle (Autodev #46). `heartbeat` is different — it carries
  # an issue_id: it is the per-danger-claude-call liveness marker that bounds a
  # live worker's silence (Autodev #50, DangerClaudeRunner#dc_heartbeat!).
  # `discussions_snapshot` (DiscussionSnapshot.capture) is rendered in the issue
  # timeline and broadcast to /stream like any other row.
  #
  # This list is descriptive, not enforced: it documents the kinds writers use,
  # it is not a DB-level or model-level constraint. Do not add
  # `validates :kind, inclusion:` — ActivityLogger writes with non-bang
  # ActivityEvent.create and swallows failures, so an inclusion validation
  # would silently stop logging the first time anyone introduces an unlisted
  # kind, which is strictly worse than this comment being stale.
  KINDS = %w[transition danger_claude poller error usage heartbeat discussions_snapshot].freeze
  LEVELS = %w[info warn error].freeze

  belongs_to :issue, optional: true

  # The legacy Sequel migration created `created_at` as a TEXT column (the
  # Rails migration's `create_table … if_not_exists: true` is a no-op on the
  # pre-existing prod table), so AR otherwise treats it as :string and stores
  # `Time#to_s` — i.e. "2026-06-11 11:13:03 UTC", with a literal " UTC" that
  # SQLite's `date()` can't parse (returns NULL). That silently zeroed the
  # dashboard "Activité de la semaine" sparkline. Declaring it :datetime makes
  # AR emit the suffix-free 'YYYY-MM-DD HH:MM:SS' format `date()` understands —
  # same fix the Issue model already applies to its timestamp columns.
  attribute :created_at, :datetime

  after_create_commit :broadcast_to_event_bus

  # Rows that exist for one reader only: Issue.without_activity_since, which
  # bounds how long a live worker may stay silent before dispatch_dormant_audit
  # repositions its row (Autodev #50). They are machinery, not activity anyone
  # asked to see, so every path that *renders* events goes through this scope —
  # one definition rather than a `where.not` repeated per consumer. The
  # staleness query itself must NOT use it: counting the heartbeat is the whole
  # mechanism.
  scope :user_visible, -> { where.not(kind: 'heartbeat') }

  def payload
    return {} if payload_json.nil? || payload_json.empty?

    JSON.parse(payload_json)
  rescue JSON::ParserError
    {}
  end

  def payload=(hash)
    self.payload_json = JSON.generate(hash || {})
  end

  private

  # The EventBus is only present when the Rails web server has booted
  # `lib/autodev/web/event_bus.rb` (still true today — the Phlex views
  # under lib/autodev/web/views/ depend on it for /stream SSE). In CLI /
  # job-only contexts the constant is undefined and we silently skip.
  def broadcast_to_event_bus
    return unless defined?(Web::EventBus)
    # System events (poller heartbeats, cycle-failure markers) carry no issue_id.
    # They feed Autodev::HealthReport, not the per-issue SSE activity feed — and
    # broadcasting a 5-minute heartbeat would spam /stream. Skip them here.
    return if issue_id.nil?
    # danger-claude liveness markers DO carry an issue_id, so the guard above
    # does not cover them: one frame per call would flood the feed (Autodev #50).
    return if kind == 'heartbeat'

    Web::EventBus.publish(self)
  rescue StandardError
    nil
  end
end

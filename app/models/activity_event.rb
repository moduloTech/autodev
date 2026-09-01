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
  # `review_skill` is the same shape as `usage`: the per-cycle verdict on whether
  # each project declaring a `review_skill` actually carries it, recorded once by
  # Autodev::ReviewSkillProbe and read passively by HealthReport (Autodev #81).
  # `mr_review_token` is the same shape again (Autodev #80): the per-cycle verdict
  # on whether GitLab still accepts the credential the `mr-review` binary runs
  # with, recorded by Autodev::MrReviewTokenProbe — and only while some project
  # still reviews through that binary. It carries the *name* of the configuration
  # key the credential came from, never its value.
  # `discussions_snapshot` (DiscussionSnapshot.capture) is rendered in the issue
  # timeline and broadcast to /stream like any other row.
  #
  # This list is descriptive, not enforced: it documents the kinds writers use,
  # it is not a DB-level or model-level constraint. Do not add
  # `validates :kind, inclusion:` — ActivityLogger writes with non-bang
  # ActivityEvent.create and swallows failures, so an inclusion validation
  # would silently stop logging the first time anyone introduces an unlisted
  # kind, which is strictly worse than this comment being stale.
  KINDS = %w[transition danger_claude poller error usage heartbeat review_skill mr_review_token
             discussions_snapshot].freeze
  LEVELS = %w[info warn error].freeze

  # The kinds that exist for the machinery, not for a reader: liveness and
  # per-cycle verdicts, each written on a clock rather than in response to work.
  # Every one of them has exactly one reader, and that reader only ever wants
  # the newest row — `HealthReport#check_poller`, `UsageGate.state`, and
  # `Issue.without_activity_since` for the heartbeat. That is what makes them
  # both invisible (`user_visible` below) and disposable
  # (Autodev::ActivityEventJanitor, Autodev #57): a row nobody asked to see and
  # nobody will read again is a row we may delete.
  MACHINERY_KINDS = %w[poller error usage heartbeat review_skill mr_review_token].freeze

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

  # The one definition of "a row somebody asked to see". Every path that
  # *renders* events goes through it — the issue timeline, the dashboard
  # sparkline, the /stream guard — rather than repeating a `where.not` per
  # consumer. It hid `heartbeat` alone until Autodev #57; the sparkline mean-
  # while carried its own hardcoded `poller`/`error`/`heartbeat` list, and the
  # gap between the two lists is how `usage` came to make the majority of the
  # sparkline once Autodev #53 collapsed the per-poll danger_claude row.
  #
  # The staleness query must NOT use this scope: `Issue.without_activity_since`
  # counting the heartbeat is the whole mechanism of Autodev #50.
  scope :user_visible, -> { where.not(kind: MACHINERY_KINDS) }

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

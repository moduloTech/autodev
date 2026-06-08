# frozen_string_literal: true

# Authoritative ActivityEvent model (railsification step 2 second half).
#
# Replaces the dynamically-built `Sequel::Model(db[:activity_events])` that
# `Database.build_activity_event_model!` used to const_set at boot. The SSE
# fan-out moved from Sequel's `after_create` hook to AR's
# `after_create_commit` so subscribers only see events the DB actually
# accepted (rolled-back transactions no longer leak partial state).
class ActivityEvent < ApplicationRecord
  KINDS = %w[transition danger_claude poller error].freeze
  LEVELS = %w[info warn error].freeze

  belongs_to :issue, optional: true

  after_create_commit :broadcast_to_event_bus

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

    Web::EventBus.publish(self)
  rescue StandardError
    nil
  end
end

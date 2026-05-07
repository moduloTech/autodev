# frozen_string_literal: true

# Behavior mixed into the dynamically-built ActivityEvent Sequel::Model.
# The model is created in Database.build_model! after the DB connection is open.
module ActivityEventBehavior
  KINDS = %w[transition danger_claude poller error].freeze
  LEVELS = %w[info warn error].freeze

  def payload
    return {} if payload_json.nil? || payload_json.empty?

    JSON.parse(payload_json)
  rescue JSON::ParserError
    {}
  end

  def payload=(hash)
    self.payload_json = JSON.generate(hash || {})
  end

  # Sequel hook: fan out to live SSE subscribers after each create.
  # Best-effort; the EventBus may not be loaded in non-web contexts.
  def after_create
    super
    return unless defined?(Web::EventBus)

    Web::EventBus.publish(self)
  rescue StandardError
    nil
  end
end

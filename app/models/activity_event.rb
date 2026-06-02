# frozen_string_literal: true

# ActiveRecord mirror of the `activity_events` table — phase A.
#
# The Sequel-side `ActivityEventBehavior` has an `after_create` that fans out
# to `Web::EventBus` (Sinatra SSE). The AR side does NOT publish — Rails has
# no live consumers in phase A, and we don't want two writers competing on
# the in-process pub/sub.
class ActivityEvent < ApplicationRecord
  self.table_name = 'activity_events'

  belongs_to :issue, optional: true

  def payload
    return {} if payload_json.nil? || payload_json.empty?

    JSON.parse(payload_json)
  rescue JSON::ParserError
    {}
  end

  def payload=(hash)
    self.payload_json = JSON.generate(hash || {})
  end
end

# frozen_string_literal: true

# Autodev #96: one row per GitLab transport failure — the outage family
# GitlabHelpers::TRANSPORT_ERRORS already names (Autodev #62's third round).
# Written by GitlabRequestCounter whenever a wrapped client call raises one
# of those errors. Read back by Autodev::HealthReport's `gitlab_requests`
# check, which is what turns four hand-timed samples (the instruction's
# point 3) into an actual rate and an actual hourly curve.
#
# A log, not a counter (contrast GitlabRequestStat): at the observed 1-2%
# background failure rate this is tens of rows a day, and each one needs its
# own timestamp to place it on a curve.
class GitlabTransportFailure < ApplicationRecord
  class << self
    # Fails closed like GitlabRequestStat.record! — instrumenting a failure
    # must never itself raise and mask the original one, which is already on
    # its way back to the caller by the time this runs.
    def record!(kind:, endpoint:, error:, caller_location: nil, at: Time.current)
      create!(
        occurred_at: at.utc, kind: kind.to_s, endpoint: endpoint.to_s,
        error_class: error.class.name, error_message: error.message.to_s.first(500),
        caller_location: caller_location
      )
      nil
    rescue StandardError
      nil
    end

    def count_since(since) = where(occurred_at: since..).count

    def recent(limit: 5) = order(occurred_at: :desc).limit(limit)
  end
end

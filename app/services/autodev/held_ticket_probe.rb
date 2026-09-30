# frozen_string_literal: true

module Autodev
  # Which requests autodev no longer follows still hold their GitLab ticket?
  # (Autodev #126.)
  #
  # A `done` or `closed` row whose ticket is still assigned to the bot is on
  # nobody's list: the bot's own list is read by nobody, and autodev stops
  # reading a ticket once its row is terminal. Measured on 28/09/2026: 8 such
  # rows on powerpanne/core, from four different causes (abandons before the
  # #98 handback, a label handover that closed the row and left the ticket, a
  # TCP timeout that escaped the `done` sequence, a dashboard close). Fixing the
  # causes does not empty the stock, and the next cause will not announce
  # itself either — this is the observation that would.
  #
  # The price: one `issues?state=opened&assignee_id=<bot>` list per project, at
  # most every `INTERVAL` — two projects, at most 192 reads a day, one page each
  # at the current stock (20 tickets). Observation only: the repair gesture is
  # the dashboard's Clore for a `done` row, GitLab for a `closed` one.
  #
  # Persisted, not recomputed by its reader, for `ReviewSkillProbe`'s reason:
  # `HealthReport` is passive by contract and never calls GitLab.
  #
  # Fails open, per Autodev #62: a project GitLab did not answer about is
  # counted in `unknown` and contributes no row, so an outage never reads as
  # "nothing held".
  class HeldTicketProbe
    KIND = 'held_ticket'
    INTERVAL = 15.minutes
    # Three intervals: a record survives two missed probes before the card
    # stops trusting it.
    TTL = 3 * INTERVAL
    TERMINAL_STATUSES = %w[done closed].freeze

    class << self
      # Returns the recorded payload (`{ held:, checked:, unknown: }`), or nil
      # when the last probe is younger than `INTERVAL` and nothing was asked.
      def probe!(config:, projects:, client: nil, logger: nil, now: Time.current)
        return nil unless due?(now)

        paths = Array(projects).filter_map { |project| project['path'].presence }
        return nil if paths.empty?

        client ||= ::GitlabHelpers.build_gitlab_client(config['gitlab_url'], config['gitlab_token'])
        payload = survey(client, paths, logger)
        record(payload, now)
        payload
      rescue StandardError => e
        # An advisory check must never be what breaks a poll cycle.
        logger&.warn("[held_ticket_probe] probe failed: #{e.class}: #{e.message}")
        nil
      end

      # `checked_at` is nil when no record younger than `TTL` is on file — which
      # is exactly when the empty list is the default rather than good news.
      def state(now: Time.current)
        event = last_event
        return unknown if event.nil? || (now - event.created_at) > TTL

        payload = event.payload
        return unknown unless payload['held'].is_a?(Array)

        { held: payload['held'], checked: payload['checked'].to_i, unknown: payload['unknown'].to_i,
          checked_at: event.created_at }
      rescue StandardError
        unknown
      end

      private

      def unknown = { held: [], checked: 0, unknown: 0, checked_at: nil }

      def due?(now)
        event = last_event
        event.nil? || (now - event.created_at) >= INTERVAL
      end

      # A bot id GitLab would not give is an outage on every project at once,
      # not a crash: the record still says what could not be read.
      def survey(client, paths, logger)
        bot_id = bot_id_of(client, logger)
        lists = paths.to_h { |path| [path, bot_id && held_iids(client, path, bot_id, logger)] }
        readable = lists.compact
        { held: terminal_rows(readable), checked: paths.size, unknown: paths.size - readable.size }
      end

      def bot_id_of(client, logger)
        ::GitlabHelpers.current_user_id(client)
      rescue *::GitlabHelpers::TRANSPORT_ERRORS => e
        logger&.warn("[held_ticket_probe] bot id unreadable: #{e.class}: #{e.message}")
        nil
      end

      # Every page: the bot's list is 20 tickets today and GitLab pages lists,
      # so a ticket past the first page would be held unseen (Autodev #116).
      def held_iids(client, path, bot_id, logger)
        client.issues(path, state: 'opened', assignee_id: bot_id, per_page: 100)
              .auto_paginate.map { |ticket| ::GitlabHelpers.field(ticket, :iid).to_i }
      rescue *::GitlabHelpers::TRANSPORT_ERRORS => e
        logger&.warn("[held_ticket_probe] #{path} unreadable: #{e.class}: #{e.message}")
        nil
      end

      # Joined on the project too: an iid is unique only inside its project.
      def terminal_rows(lists)
        lists.flat_map do |path, iids|
          next [] if iids.empty?

          Issue.where(project_path: path, issue_iid: iids, status: TERMINAL_STATUSES).order(:id).map do |issue|
            { 'id' => issue.id, 'path' => path, 'iid' => issue.issue_iid, 'status' => issue.status }
          end
        end
      end

      # Recorded even when nothing is held: that is the good news, and it is
      # also what spaces the next probe.
      def record(payload, now)
        ActivityEvent.create(
          issue_id: nil, kind: KIND, level: payload[:held].any? ? 'warn' : 'info',
          payload_json: JSON.generate(payload), created_at: now
        )
      rescue StandardError
        nil # fire-and-forget: an unrecordable probe just means "unknown"
      end

      def last_event
        ActivityEvent.where(kind: KIND).order(created_at: :desc, id: :desc).first
      end
    end
  end
end

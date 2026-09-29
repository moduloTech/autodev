# frozen_string_literal: true

module Autodev
  # The GitLab half of the dashboard's Clore (Autodev #126): a row closed while
  # the bot still holds its ticket leaves that ticket on a list nobody reads.
  # This hands it to `Issue#handback_target`, the same rule `hand_ticket_back`
  # applies on a give-up, and only when the bot is an assignee — a ticket a
  # human already holds is theirs, and taking it from them to give it back to
  # the author would be the #98 mistake.
  #
  # It never raises for GitLab: the close has already happened and must hold
  # whatever GitLab answers (owner's decision), so an outage becomes a
  # `:failed` result the controller tells the operator about. A programming
  # error still travels as itself — `GitlabHelpers::TRANSPORT_ERRORS` states
  # that rule, and a `rescue StandardError` here would break it.
  class CloseHandback
    Result = Struct.new(:outcome, :target_id, :target_name, :error)

    # `ConfigError` is what `build_gitlab_client` raises without a token or URL;
    # `ApiUnavailableError` is what a read wrapped by `GitlabHelpers.answer`
    # (or the request counter) raises for the same outage.
    FAILURES = [*::GitlabHelpers::TRANSPORT_ERRORS, ::ApiUnavailableError, ::ConfigError].freeze

    def self.perform(issue, config:, logger:)
      new(config: config, logger: logger).perform(issue)
    end

    def initialize(config:, logger:)
      @config = config
      @logger = logger
    end

    def perform(issue)
      target = issue.handback_target
      client = ::GitlabHelpers.build_gitlab_client(@config['gitlab_url'], @config['gitlab_token'])
      return Result.new(:not_held) unless held_by_bot?(client, issue)
      # An `assignee_ids: [nil]` edit would unassign the ticket: worse than
      # leaving it on the bot, where the health card can still see it.
      return Result.new(:no_target) unless target

      hand_to(client, issue, target)
    rescue *FAILURES => e
      failed(issue, target, e)
    end

    private

    def hand_to(client, issue, target)
      response = client.edit_issue(issue.project_path, issue.issue_iid, assignee_ids: [target])
      return not_landed(issue, target) unless ::GitlabHelpers.assigned_to?(response, target)

      @logger&.info("Handed issue ##{issue.issue_iid} back to user #{target} on close")
      Result.new(:handed_back, target, name_of(response, target))
    end

    def held_by_bot?(client, issue)
      bot_id = ::GitlabHelpers.current_user_id(client)
      ::GitlabHelpers.assigned_to?(client.issue(issue.project_path, issue.issue_iid), bot_id)
    end

    # GitLab answered 200 and the payload it returned does not carry the target:
    # the write was accepted and not honoured (a deactivated account, GitLab
    # Community's one-assignee rule). Not a handback, so not claimed as one.
    def not_landed(issue, target)
      message = "GitLab accepted the reassignment but the ticket is not assigned to user #{target}"
      @logger&.error("Issue ##{issue.issue_iid}: #{message}")
      Result.new(:failed, target, nil, message)
    end

    def name_of(response, target)
      assignee = Array(response && ::GitlabHelpers.field(response, :assignees))
                 .find { |a| ::GitlabHelpers.field(a, :id) == target }
      name = assignee && ::GitlabHelpers.field(assignee, :name)
      name.presence || target.to_s
    end

    def failed(issue, target, error)
      message = ::Redactor.scrub(error.message)
      @logger&.error("Failed to hand issue ##{issue.issue_iid} back on close: #{message}")
      Result.new(:failed, target, nil, message)
    end
  end
end

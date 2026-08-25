# frozen_string_literal: true

module Autodev
  # One definition of "the human answered the question autodev asked, so the
  # request goes back into the queue" (Autodev #75).
  #
  # Two callers, and they must never disagree about either half:
  #
  # - `PollDispatcher#process_issue`, the live path, reached once
  #   `Issue::PROCESSABLE_STATES` lets a `needs_clarification` row through the
  #   router;
  # - `ClarificationSweep`, the one-shot catch-up for the requests that were
  #   already parked when the router was fixed.
  #
  # `answered?` deliberately **raises** rather than answering `false` when GitLab
  # cannot be read (`GitlabHelpers.answer`, Autodev #62). Each caller declares its
  # own boundary: the poller re-asks next cycle, the sweep skips that row and
  # reports it. Neither may read an outage as "nobody replied" — this class has no
  # return value that means "unknown", on purpose.
  class ClarificationResume
    def initialize(client:, path:, logger:)
      @client = client
      @path = path
      @logger = logger
    end

    # A row with no `clarification_requested_at` reads as answered — same rule as
    # `GitlabHelpers.clarification_answered?` has always applied at the poll call
    # site. There is no question on record to wait for, and leaving such a row
    # parked forever is the failure this ticket is about.
    def answered?(issue)
      ::GitlabHelpers.clarification_answered?(
        @client, @path, issue.issue_iid, issue.clarification_requested_at
      )
    end

    def resume!(issue)
      @logger.info("Issue ##{issue.issue_iid}: clarification received, re-queuing", project: @path)
      issue.clarification_received!
      issue.update(clarification_requested_at: nil, error_message: nil)
      ::ActivityLogger.post(::ActivityLogger::Ctx.new(@client, @path, @logger),
                            issue, :clarification_received)
    end
  end
end

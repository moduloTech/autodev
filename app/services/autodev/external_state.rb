# frozen_string_literal: true

module Autodev
  # What GitLab says about a ticket, and the two writes that follow when the
  # answer is "not ours anymore".
  #
  # Two passes need this and must never disagree: `dispatch_unassignment`
  # sweeps active rows every cycle (Autodev #44), and `dispatch_dormant_audit`
  # sweeps dormant ones behind a backoff (#47/#48). #48 exists precisely because
  # this decision lived in one pass while the other population was never swept —
  # so it lives in one module now, with two includers.
  #
  # The includer must expose `@client`, `@path` and `@logger`.
  module ExternalState
    def externally_closed?(gl_issue)
      ::GitlabHelpers.field(gl_issue, :state) == 'closed'
    end

    def assigned_to_autodev?(gl_issue)
      (::GitlabHelpers.field(gl_issue, :assignees) || [])
        .any? { |a| ::GitlabHelpers.field(a, :id) == ::GitlabHelpers.current_user_id(@client) }
    end

    # Mirrors IssuesController#close_issue!, minus the audit actor: nobody
    # clicked anything, the ticket just went away on GitLab. `error_message` is
    # deliberately preserved — /errors stops listing the row, /issues/:id still
    # explains why it failed.
    def close_externally(issue)
      return unless issue.may_close?

      @logger.info("Issue ##{issue.issue_iid}: closed on GitLab, closing locally", project: @path)
      issue.close!
      ::Issue.where(id: issue.id).update_all(finished_at: Time.current, needs_attention: false,
                                             attention_reason: nil, attention_detail: nil)
      ::ActivityLogger.post(::ActivityLogger::Ctx.new(@client, @path, @logger),
                            issue, :closed_externally)
    end

    def stop_unassigned(issue)
      @logger.info("Issue ##{issue.issue_iid}: no longer assigned, transitioning to done",
                   project: @path)
      issue.update(status: 'done', finished_at: Time.current)
      ::ActivityLogger.post(::ActivityLogger::Ctx.new(@client, @path, @logger),
                            issue, :unassigned_stop)
    end
  end
end

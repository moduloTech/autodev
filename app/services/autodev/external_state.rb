# frozen_string_literal: true

module Autodev
  # What GitLab says about a ticket, and the writes that follow when the answer
  # is "not ours anymore".
  #
  # Two passes need this and must never disagree: `dispatch_unassignment`
  # sweeps active rows every cycle (Autodev #44), and `dispatch_dormant_audit`
  # sweeps dormant ones behind a backoff (#47/#48). #48 exists precisely because
  # this decision lived in one pass while the other population was never swept —
  # so it lives in one module now, with two includers.
  #
  # Three questions are asked, in a fixed order, and the order is load-bearing:
  # closed on GitLab, then no longer assigned, then handed over via the labels
  # (Autodev #52). A ticket that went away or was reassigned is not ours whatever
  # its labels say.
  #
  # The includer must expose `@client`, `@path`, `@project_config` and `@logger`.
  module ExternalState
    def externally_closed?(gl_issue)
      ::GitlabHelpers.field(gl_issue, :state) == 'closed'
    end

    def assigned_to_autodev?(gl_issue)
      (::GitlabHelpers.field(gl_issue, :assignees) || [])
        .any? { |a| ::GitlabHelpers.field(a, :id) == ::GitlabHelpers.current_user_id(@client) }
    end

    # Mirrors IssuesController#close_issue!, minus the audit actor: nobody
    # clicked anything, the ticket just went away on GitLab.
    def close_externally(issue)
      return unless issue.may_close?

      @logger.info("Issue ##{issue.issue_iid}: closed on GitLab, closing locally", project: @path)
      close_row!(issue, :closed_externally)
    end

    # `closed`, not `done` (Autodev #52). A ticket a human pulled back was never
    # delivered, and #44 already settled that `closed` says more than `done` for
    # the sibling case. One consequence is deliberate: the row leaves
    # `dispatch_done_unassigned`'s population, so the post_completion hook stops
    # running over a half-finished MR. Every nominal completion reaches `done`
    # *before* reassigning the author, and only active rows are swept here, so
    # the population that hook exists for is untouched.
    def stop_unassigned(issue)
      return unless issue.may_close?

      @logger.info("Issue ##{issue.issue_iid}: no longer assigned, stopping and closing",
                   project: @path)
      notify_stop(issue, :unassigned_stop)
      close_row!(issue, :unassigned_stop)
    end

    # Autodev is still the assignee and the ticket is still open — but did
    # somebody move it on with the labels? Returns the verdict that closed the
    # row, or nil, so `DormantAudit` can tell a handover apart from "still ours"
    # and not re-arm a ticket a human has taken over.
    #
    # See Autodev::LabelHandover for the rule and for why a healthy ticket costs
    # no extra GitLab call.
    def stop_on_handover(issue, gl_issue)
      return unless issue.may_close?

      verdict = label_handover.verdict(gl_issue, issue.issue_iid)
      return unless verdict

      key = :"handover_#{verdict.reason}"
      @logger.info("Issue ##{issue.issue_iid}: #{verdict.reason} (#{verdict.label}), " \
                   'stopping and closing', project: @path)
      notify_stop(issue, key, label: verdict.label)
      close_row!(issue, key, label: verdict.label)
      verdict
    end

    private

    def label_handover
      LabelHandover.new(client: @client, path: @path,
                        project_config: @project_config, logger: @logger)
    end

    # The one terminal write. The three outcomes above differ only by the
    # activity entry they leave behind; #48 exists because two passes disagreed
    # about this decision, so the write itself stays in one place.
    #
    # `error_message` is deliberately preserved — /errors stops listing the row,
    # /issues/:id still explains why it failed.
    def close_row!(issue, activity_key, **vars)
      issue.close!
      ::Issue.where(id: issue.id).update_all(finished_at: Time.current, needs_attention: false,
                                             attention_reason: nil, attention_detail: nil)
      ::ActivityLogger.post(::ActivityLogger::Ctx.new(@client, @path, @logger),
                            issue, activity_key, **vars)
    end

    # The GitLab comment that makes the stop visible (Autodev #52). The activity
    # log alone was not enough: it is one line appended to a folded note nobody
    # re-reads, so a human who unassigned autodev never learned whether it had
    # actually stopped.
    #
    # Sibling of `IssueNotifier#notify_localized`, which this layer cannot reuse:
    # the includers are poll-cycle services with `@path`, not DangerClaudeRunner
    # hosts with `@project_path` and the whole mixin stack.
    def notify_stop(issue, key, **vars)
      message = ::Locales.t(key, locale: (issue.locale || 'fr').to_sym,
                                 tag: ::ActivityLogger.tag, label_todo: first_labels_todo, **vars)
      @client.create_issue_note(@path, issue.issue_iid, message)
    # A write (Autodev #62 scopes writes out of the read rule): a stop notice
    # that could not be posted reports what happened, it invents nothing, so
    # this stays non-fatal. Widened from `Gitlab::Error::ResponseError` alone to
    # the whole transport family (Autodev #115): a `Net::ReadTimeout` or
    # `Errno::ECONNRESET` posting this note used to escape uncaught, unlike
    # every other write-swallow in this codebase.
    rescue *::GitlabHelpers::TRANSPORT_ERRORS => e
      @logger.error("Failed to post the stop notice on ##{issue.issue_iid}: #{e.message}",
                    project: @path)
    end

    # May be nil when a project configures no todo label — same as `done_nominal`
    # already does with it.
    def first_labels_todo = Array((@project_config || {})['labels_todo']).first
  end
end

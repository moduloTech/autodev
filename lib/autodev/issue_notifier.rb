# frozen_string_literal: true

require_relative 'activity_logger'

# Extracted from DangerClaudeRunner to reduce module length.
# Provides GitLab issue notification, assignment, and context file helpers.
#
# Including classes must have @client, @project_config, @project_path, and @logger.
module IssueNotifier
  include ActivityLogger

  private

  def assign_to_self(iid)
    me = @client.user
    @client.edit_issue(@project_path, iid, assignee_ids: [me.id])
    log "Assigned issue ##{iid} to #{me.username}"
  rescue Gitlab::Error::ResponseError => e
    log_error "Failed to assign issue ##{iid} to self: #{e.message}"
  end

  # Returns whether the ticket actually changed hands (Autodev #60): the abandon
  # notification only claims a handback when there was somebody to hand it to and
  # GitLab accepted the edit. Existing callers ignore the value.
  #
  # Named for the gesture rather than for the recipient since Autodev #98, because
  # the recipient is no longer always the author — see `handback_target`.
  #
  # A request that never completed answers `false` like an HTTP refusal
  # (Autodev #125) instead of escaping into the caller's `rescue StandardError`
  # after the row has already been given up. For a timeout `false` is not
  # established — the edit may have landed — and that errs in the safe
  # direction: the notice leaves a handback that did happen unclaimed, and
  # never claims one that did not.
  def hand_ticket_back(issue)
    target = handback_target(issue)
    return false unless target

    @client.edit_issue(@project_path, issue.issue_iid, assignee_ids: [target])
    log "Handed issue ##{issue.issue_iid} back to user #{target}"
    true
  rescue ::Gitlab::Error::ResponseError, ::SystemCallError, ::Timeout::Error, ::SocketError,
         ::OpenSSL::SSL::SSLError, ::EOFError => e
    log_error "Failed to hand issue ##{issue.issue_iid} back: #{e.class}: #{e.message}"
    false
  end

  # What a round announces after it has already moved the row (Autodev #125):
  # the transition is the verdict, and a GitLab write that follows it cannot
  # undo it, so a failure costs that write and nothing else. Returns the block's
  # value, or nil when the write was lost.
  #
  # Deliberately not folded into `notify_issue`: that is also how
  # `QuestionHandler#post_answer` delivers an answer *before* transitioning, and
  # swallowing a cut there would mark a ticket answered with no answer posted.
  # The family is spelled out rather than splatted so the #62 scanner can read
  # the clause (Autodev #119).
  def after_conclusion(what)
    yield
  rescue ::Gitlab::Error::ResponseError, ::SystemCallError, ::Timeout::Error, ::SocketError,
         ::OpenSSL::SSL::SSLError, ::EOFError => e
    log_error "Lost the #{what} write after the row moved on: #{e.class}: #{e.message}"
    nil
  end

  # Whoever autodev took the ticket from, and the author otherwise (Autodev #98).
  #
  # GitLab Community holds one assignee, so `ReviewArrearsSweep` cannot add
  # autodev beside a human — it replaces them, and records who in
  # `displaced_assignee_id`. Handing such a ticket to its *author* would move it
  # to somebody who never had it: on the 20 rows of the #88 arrears that is a
  # different person 4 times, and one of those authors is a deactivated account,
  # so the ticket would come to rest on nobody.
  #
  # The author stays the answer everywhere else, which is every row autodev was
  # assigned to in the ordinary way — the column is NULL there and nothing about
  # those paths changes.
  def handback_target(issue)
    issue.displaced_assignee_id || issue.issue_author_id
  end

  def autodev_tag
    "**autodev** (v#{Autodev::VERSION})"
  end

  def notify_issue(iid, message)
    @client.create_issue_note(@project_path, iid, message)
  rescue Gitlab::Error::ResponseError => e
    log_error "Failed to post comment on ##{iid}: #{e.message}"
  end

  # `suffix:` appends a second, var-free template after a blank line (Autodev
  # #60). Each give-up reason needs its own sentence — collapsing them into one
  # generic message would lose what actually happened — but they share the "and I
  # handed the ticket back to its author" clause, and duplicating that across one
  # template per reason × two locales is how the next one gets forgotten.
  def notify_localized(iid, key, suffix: nil, **vars)
    issue_record = Issue.where(project_path: @project_path, issue_iid: iid).first
    locale = (issue_record&.locale || 'fr').to_sym
    message = Locales.t(key, locale: locale, tag: autodev_tag, **vars)
    message = "#{message}\n\n#{Locales.t(suffix, locale: locale)}" if suffix
    notify_issue(iid, message)
  end

  # -- Context file --

  # Writes the context file, yields, then guarantees cleanup.
  # Returns the block's return value.
  def with_context_file(work_dir, branch_name, content)
    context_file = GitlabHelpers.write_context_file(work_dir, branch_name, content)
    yield context_file
  ensure
    GitlabHelpers.cleanup_context_file(work_dir, branch_name)
  end
end

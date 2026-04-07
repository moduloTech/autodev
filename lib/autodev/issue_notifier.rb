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

  def reassign_to_author(issue)
    return unless issue.issue_author_id

    @client.edit_issue(@project_path, issue.issue_iid, assignee_ids: [issue.issue_author_id])
    log "Reassigned issue ##{issue.issue_iid} to author (user #{issue.issue_author_id})"
  rescue Gitlab::Error::ResponseError => e
    log_error "Failed to reassign issue ##{issue.issue_iid} to author: #{e.message}"
  end

  def autodev_tag
    "**autodev** (v#{Autodev::VERSION})"
  end

  def notify_issue(iid, message)
    @client.create_issue_note(@project_path, iid, message)
  rescue Gitlab::Error::ResponseError => e
    log_error "Failed to post comment on ##{iid}: #{e.message}"
  end

  def notify_localized(iid, key, **vars)
    issue_record = Issue.where(project_path: @project_path, issue_iid: iid).first
    locale = (issue_record&.locale || 'fr').to_sym
    message = Locales.t(key, locale: locale, tag: autodev_tag, **vars)
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

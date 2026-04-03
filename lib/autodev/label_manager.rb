# frozen_string_literal: true

# Extracted from DangerClaudeRunner to reduce module length.
# Manages GitLab issue labels for the autodev workflow.
#
# Including classes must have @client, @project_config, @project_path, and @logger.
module LabelManager
  private

  def label_workflow?
    Config.label_workflow?(@project_config)
  end

  def apply_label_doing(iid)
    return unless label_workflow?

    remove = @project_config['labels_todo'] + [@project_config['label_mr'], @project_config['label_blocked']]
    manage_labels(iid, remove: remove, add: @project_config['label_doing'])
  end

  def apply_label_mr(iid)
    return unless label_workflow?

    remove = @project_config['labels_todo'] + [@project_config['label_doing'], @project_config['label_blocked']]
    manage_labels(iid, remove: remove, add: @project_config['label_mr'])
  end

  def apply_label_todo(iid)
    return unless label_workflow?

    remove = [@project_config['label_doing'], @project_config['label_mr'], @project_config['label_blocked']]
    manage_labels(iid, remove: remove, add: @project_config['labels_todo'].first)
  end

  def apply_label_blocked(iid)
    return unless label_workflow?

    remove = @project_config['labels_todo'] + [@project_config['label_doing'], @project_config['label_mr']]
    manage_labels(iid, remove: remove, add: @project_config['label_blocked'])
  end

  def cleanup_labels(iid)
    return unless label_workflow?

    all_labels = @project_config['labels_todo'] +
                 [@project_config['label_doing'], @project_config['label_mr'],
                  @project_config['label_done'], @project_config['label_blocked']]
    manage_labels(iid, remove: all_labels.compact, add: nil)
  end

  def manage_labels(iid, remove:, add:)
    gi = @client.issue(@project_path, iid)
    current = gi.labels || []
    new_labels = current - remove.compact
    new_labels << add if add && !new_labels.include?(add)
    @client.edit_issue(@project_path, iid, labels: new_labels.join(','))
    removed = current & remove.compact
    log "Labels updated on ##{iid}: removed #{removed}, added #{add}" if removed.any? || add
  rescue Gitlab::Error::ResponseError => e
    log_error "Failed to update labels for ##{iid}: #{e.message}"
  end
end

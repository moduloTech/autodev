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

    doing = @project_config['label_doing']
    manage_labels(iid, remove: other_workflow_labels(doing), add: doing)
  end

  def apply_label_done(iid)
    return unless label_workflow?

    done = @project_config['label_done']
    manage_labels(iid, remove: other_workflow_labels(done), add: done)
  end

  # The end label of a give-up (Autodev #63).
  #
  # `apply_label_done` used to serve both endings, and on the projects that
  # matter `label_done` is the "ready for feature review" column: a ticket
  # autodev abandoned — five identical infra failures, an expired watch, an
  # exhausted review budget, five crashed mr-reviews — reached the PM's board
  # presented as reviewed. The comment and the reassignment said otherwise, but
  # the label is what a board reads.
  #
  # The label has to come from the project, because the scope autodev derives
  # (`label_doing` + `label_done`) names a *scope*, not its values: powerpanne
  # carries `Development::StandBy` / `Awaiting CR` / `Awaiting Merge` beside the
  # three configured ones and ff/fast/core carries only `NeedEstimation` —
  # nothing autodev could pick without guessing which one a given board means by
  # "somebody has to look at this".
  #
  # Absent, the fallback is to write no end label at all and leave the row on
  # `label_doing`: a ticket that looks still in progress is a smaller lie than a
  # ticket that looks reviewed, and it costs no GitLab call.
  def apply_label_attention(iid)
    return unless label_workflow?

    attention = label_attention
    return log "No label_attention configured on #{@project_path}, leaving ##{iid} on label_doing" unless attention

    manage_labels(iid, remove: other_workflow_labels(attention), add: attention)
  end

  # Every workflow label autodev owns and writes, except the one being applied.
  # `label_attention` belongs in here as much as the others: a re-armed row
  # (`dispatch_infra_recheck` → `resume_recovered_infra` → `apply_label_doing`)
  # must not keep a stale attention label beside its new one, since GitLab allows
  # a single value per scope and the two would collide.
  def other_workflow_labels(applied)
    (Array(@project_config['labels_todo']) +
      [@project_config['label_doing'], @project_config['label_done'], label_attention])
      .compact.uniq - [applied]
  end

  # Blank is "not configured", not a label named "".
  def label_attention
    value = @project_config['label_attention'].to_s.strip
    value.empty? ? nil : value
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

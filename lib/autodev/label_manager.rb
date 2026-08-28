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
    remember_entry_label(manage_labels(iid, remove: other_workflow_labels(doing), add: doing))
  end

  # The entry label, put back while autodev waits on a human (Autodev #75).
  #
  # `dispatch_new_issues` discovers by asking GitLab for the issues assigned to
  # autodev **and** carrying a `labels_todo` label, so a request whose ticket
  # stays on `label_doing` leaves the population the moment the question is
  # asked. It is also the honest label: during the wait the ticket is in the
  # hands of the person who was asked, and showing it as work in progress is a
  # lie about the board — the lie that let 12 requests sleep for up to three
  # months.
  #
  # Which value: `labels_todo` is a list, and on powerpanne both of its entries
  # are in live use by different people (`To do`, `Development::ToDo` — read off
  # the parked tickets' resource label events). So the one autodev strips on
  # pickup is the one it puts back, and the project's first declared entry label
  # is only the fallback for a request that never carried one (a `:retry_stuck`
  # re-entry, or an assignment made without touching the board). Never a guess
  # between two live board columns when the answer is known.
  def apply_label_todo(iid)
    return unless label_workflow?

    todo = entry_todo_label(carried_todo_labels(iid))
    manage_labels(iid, remove: other_workflow_labels(todo), add: todo)
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

  # Remembered from the pickup rather than re-read from GitLab: `apply_label_doing`
  # is the call that strips it, it runs in the same `IssueProcessor#process` as
  # the spec check that may ask the question, and it already computes the list it
  # removed. An `issue_label_events` call would answer the same question at the
  # cost of one API round trip on a path that has just written the labels itself.
  #
  # Only ever *set*, never cleared, and only from a non-empty intersection: a
  # later `apply_label_done` removing nothing must not erase what the pickup
  # learned.
  def remember_entry_label(removed)
    entry = Array(removed) & Array(@project_config['labels_todo'])
    @entry_todo_label = entry.first if entry.any?
  end

  # Three answers, in decreasing order of evidence, and the middle one is what
  # the memory alone could not give.
  #
  # `apply_label_doing` only remembers what it actually *removed*, so a pickup
  # whose `edit_issue` failed remembers nothing — and the ticket is then still
  # carrying the entry label it arrived with. Falling straight through to the
  # first of the list there strips a live board column to pose another one: on
  # powerpanne it moves a ticket entered as `Development::ToDo` over to `To do`,
  # somebody else's column, which is exactly what this method exists to prevent.
  # The same shape covers a human who reposed the entry label themselves
  # (powerpanne #16261, 21/07/2026).
  #
  # Note that returning `[]` from `manage_labels`' rescue does not fix this on its
  # own: `Array(true)` and `Array([])` both intersect `labels_todo` to `[]`. The
  # honest return type is worth having, but the fix is reading the ticket.
  def entry_todo_label(carried = [])
    @entry_todo_label ||
      (Array(carried) & Array(@project_config['labels_todo'])).first ||
      Array(@project_config['labels_todo']).first
  end

  # One extra GitLab read, on a path taken fifteen times in four months (the
  # whole `spec_unclear` history), against a board-column decision taken blind.
  # It answers `[]` for an unreadable ticket, which falls back to the first
  # declared entry label — the same answer as before, never worse.
  def carried_todo_labels(iid)
    Array(@client.issue(@project_path, iid).labels) & Array(@project_config['labels_todo'])
  rescue Gitlab::Error::ResponseError => e
    log_error "Failed to read labels for ##{iid}: #{e.message}"
    []
  end

  # Blank is "not configured", not a label named "".
  def label_attention
    value = @project_config['label_attention'].to_s.strip
    value.empty? ? nil : value
  end

  # The read is unavoidable — nothing else can say what the ticket carries — but
  # the *write* is skipped when it would change nothing (Autodev #75).
  #
  # A no-op label edit is not free: GitLab records a resource label event for it,
  # and those events are the evidence `LabelHandover#by_someone_else?` and
  # `PollRouter#reenterable?` (via `todo_reapplied_after?`) read to decide whether
  # a *human* asked for something new. Every event autodev writes for nothing is
  # noise in the one record those two readers have.
  #
  # Three call shapes actually repeat. A second clarification round re-poses the
  # entry label the first one already put on (powerpanne #15842 asked twice in 13
  # minutes on 05/08/2026). A human who moves the ticket back to the entry column
  # themselves — powerpanne #16261, 21/07/2026 — must not have that edit doubled
  # by autodev's. And a duplicate `IssueProcessJob` re-applies `label_doing` or
  # `label_done` on a row that already carries it, which is the #61 shape:
  # `whiny_transitions: false` no-ops the transition and the side effects run
  # anyway.
  def manage_labels(iid, remove:, add:)
    current = @client.issue(@project_path, iid).labels || []
    wanted = target_labels(current, remove, add)
    return [] if wanted.sort == current.sort

    @client.edit_issue(@project_path, iid, labels: wanted.join(','))
    removed = current & remove.compact
    log "Labels updated on ##{iid}: removed #{removed}, added #{add}"
    removed
  rescue Gitlab::Error::ResponseError => e
    # `[]`, not the value of `log_error` — which is `Logger#error`'s `true`. The
    # method's contract is "the workflow labels it removed", and a failed write
    # removed none; `apply_label_doing` hands this straight to
    # `remember_entry_label`, where a Boolean is a type lie waiting for the next
    # reader.
    log_error "Failed to update labels for ##{iid}: #{e.message}"
    []
  end

  def target_labels(current, remove, add)
    kept = current - remove.compact
    add && !kept.include?(add) ? kept + [add] : kept
  end
end

# frozen_string_literal: true

# What a boundary does with a `RebaseConflictError` (Autodev #138): the line
# stops and goes back to a human, at once.
#
# Shared by the three units of work that rebase before they write —
# `IssueProcessor#process` (a re-implementation on a reused branch, the row in
# `cloning`), `MrFixer#fix` (`fixing_discussions`) and `PipelineMonitor#check`
# (`checking_pipeline`). Before this, each of them carried on, on a base the
# target had left behind: implementation, fixes, then the review of the result.
#
# Why at once, when `MissingBaseBound` counts to `stagnation_threshold` first:
# that bound counts because a fetch can fail transiently, and only a confirmed
# absence is counted at all. Here nothing is transient. danger-claude has already
# had its attempt at the conflict, and the next cycle would replay the same
# commits onto the same target and meet the same refusal — paying a clone and a
# resolution each time to learn nothing.
#
# Two sinks beyond `abandon_issue`'s. The ticket comment (the abandon point's)
# reaches the requester; the merge request comment reaches the reviewer, who is
# the person reading the merge request and the one whose review would otherwise
# have judged a stale base. A row with no merge request — a run that stopped
# before `create_merge_request` — gets the ticket comment only.
#
# Expects `abandon_issue`, `after_conclusion`, `autodev_tag`, `log_error`,
# `stop_on_stale_transition` (`StaleTransitionBound`),
# @client and @project_path.
module RebaseConflictStop
  private

  # The `StaleTransitionError` clause is not decoration: this runs from inside a
  # handler that is itself a `rescue` body, so an error raised here is caught by
  # none of that handler's siblings — on `IssueProcessor#process` it would escape
  # to ActiveJob. The danger-claude resolution that precedes the raise lasts
  # minutes, which is exactly when a human closes or resets the row (Autodev #97):
  # the row then stays where they put it, and nothing is posted.
  def stop_on_rebase_conflict(issue, error)
    log_error "Issue ##{issue.issue_iid}: #{error.message} → handing back"
    vars = rebase_conflict_vars(issue, error)
    # No `detail:`: the `/errors` card renders it under "Failing job(s)", and
    # these are files. The comments carry them.
    return unless abandon_issue(issue, :rebase_conflict, **vars)

    post_rebase_conflict_mr_note(issue, vars) if issue.mr_iid
  rescue StaleTransitionError => e
    stop_on_stale_transition(e)
  end

  def rebase_conflict_vars(issue, error)
    { branch: error.branch, base: error.base, files: rebase_conflict_file_list(issue, error.files) }
  end

  # Paths in backquotes, one per line, so a long list stays readable on GitLab.
  def rebase_conflict_file_list(issue, files)
    return Locales.t(:rebase_conflict_no_files, locale: rebase_conflict_locale(issue)) if files.empty?

    files.map { |f| "- `#{f}`" }.join("\n")
  end

  # The row is already `done`: a comment lost to GitLab costs that comment and
  # nothing else (Autodev #125).
  def post_rebase_conflict_mr_note(issue, vars)
    after_conclusion(:rebase_conflict_mr_note) do
      body = Locales.t(:rebase_conflict_mr_note, locale: rebase_conflict_locale(issue), tag: autodev_tag, **vars)
      @client.create_merge_request_note(@project_path, issue.mr_iid, body)
    end
  end

  def rebase_conflict_locale(issue) = (issue.locale || 'fr').to_sym
end

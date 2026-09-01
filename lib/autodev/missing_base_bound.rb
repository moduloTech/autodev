# frozen_string_literal: true

require 'digest'
require 'json'

# What a boundary does with a `MissingTargetBranchError` (Autodev #91, review
# round, constat 3).
#
# Making that error a member of the `ApiUnavailableError` family was right for the
# reason the class documents: every boundary already knows how to end a unit of
# work that concluded nothing, with no new rescue clause anywhere. What it also
# inherited was the **waiting**, and there is nothing to wait for. A branch that
# has been deleted or renamed will not come back, and a merge request that names
# no target will not start naming one, so the row was re-enqueued by
# `dispatch_pipelines` / `dispatch_discussions` every cycle, cloned, failed, and
# logged — indefinitely, and with all four of the pipeline watch's guard-rails
# down at once:
#
#   * `PipelineMonitor#check` catches the family and logs;
#   * `abandon_expired_watch` is the last statement of `poll_open_mr`, so the
#     abort never reaches the absolute age bound;
#   * the stagnation signature is written after `clone_and_fix` returns, so the
#     abort leaves the counter untouched;
#   * `log_pipeline_poll` collapses and `supersede!` moves `created_at` forward,
#     so `Issue.without_activity_since` keeps reading the row as fresh and
#     `DormantAudit` never sees it.
#
# Each of those four is correct *for an outage*, which is exactly why the answer
# is not to weaken any of them but to stop calling this one an outage.
#
# ## What may be counted, and what may not
#
# Only evidence. `MissingTargetBranchError#confirmed?` is true when something
# authoritative said the branch is not there — `git ls-remote` answering that the
# remote has no such head, or GitLab describing a merge request that names no
# target. "The fetch did not land" and "the remote could not be asked" produce the
# same exception and are outages: they keep waiting, unbounded, exactly as before.
# That is Autodev #67's crest line — a failed read may not end a request — and it
# is the whole reason the flag exists rather than the bound being applied to the
# class.
#
# ## The shape of the ending
#
# Autodev #81's, for the same situation one layer over: the line stops, and it
# stops under a reason that names the cause, so a human is told *which branch* is
# gone on *which request* instead of it living in a log file. `abandon_issue`
# drives the three sinks (the GitLab comment, the activity line, the `/errors`
# explanation), poses `label_attention` and hands the ticket back to its author —
# who is the only person who can retarget the merge request or restore the branch.
#
# The bound is `stagnation_threshold` occurrences of the **same** branch, the
# setting this repository already uses for "the same thing keeps happening and
# nothing is moving". A different branch is a different fact and restarts the
# count, exactly like a pipeline whose failing job set changes.
#
# ## Why the counter is here rather than borrowed
#
# `issues.stagnation_signatures` is a JSON map of `key → { signature, count }` and
# two modules already bump entries in it — `StagnationDetector` for the pipeline,
# `StagnationChecker` for the discussions. Neither is reachable from both of this
# module's two callers, and one of them (`discussion_stagnated?`) carries a
# `rescue` modifier declared by name in `test/api_failure_is_not_a_verdict_test.rb`
# with a sentence about what it swallows. Borrowing either would mean either
# including a module for one method or moving a declared derogation, so this keeps
# its own entry under its own key: one bump, one read, and the one decision below
# stays in one place for both callers, which is the property that matters.
#
# Expects `stagnation_threshold`, `abandon_issue`, `log`, `log_error`.
module MissingBaseBound
  MISSING_BASE_KEY = 'target_branch'

  private

  # The one decision. Returns nothing a caller reads: the boundary that calls this
  # has already given up on the unit of work.
  def bound_missing_base(issue, error)
    log_error "Issue ##{issue.issue_iid}: #{error.message}"
    return log_unestablished_base(issue, error) unless error.confirmed?

    count = missing_base_occurrences(issue, error.branch)
    return log_missing_base_countdown(issue, error, count) if count < stagnation_threshold

    log "Issue ##{issue.issue_iid}: base `#{error.branch}` missing on #{count} consecutive attempts → done"
    abandon_issue(issue, :target_branch_missing, branch: error.branch, count: count)
  end

  # How many attempts in a row have now found *this* branch missing. The signature
  # is the branch name, so a base that changes has not recurred and the count
  # restarts — exactly like a pipeline whose failing job set changes.
  def missing_base_occurrences(issue, branch)
    data = missing_base_data(issue)
    entry = bumped(data[MISSING_BASE_KEY] || {}, Digest::SHA256.hexdigest(branch.to_s))
    data[MISSING_BASE_KEY] = entry
    issue.update(stagnation_signatures: JSON.generate(data))
    entry['count']
  end

  def bumped(entry, signature)
    return { 'signature' => signature, 'count' => 1 } unless entry['signature'] == signature

    entry.merge('count' => (entry['count'] || 0) + 1)
  end

  def missing_base_data(issue)
    JSON.parse(issue.stagnation_signatures || '{}')
  rescue JSON::ParserError
    {}
  end

  def log_unestablished_base(issue, error)
    log "Issue ##{issue.issue_iid}: the base `#{error.branch}` could not be established " \
        "(#{error.detail}); nothing concluded, not counting it"
  end

  def log_missing_base_countdown(issue, error, count)
    log "Issue ##{issue.issue_iid}: base `#{error.branch}` is not on the remote " \
        "(#{count}/#{stagnation_threshold} consecutive)"
  end
end

# frozen_string_literal: true

# The base this work is measured against could not be obtained (Autodev #91).
#
# Two ways in, one consequence. Either GitLab handed back a merge request that
# names no target branch, or the named branch is not on the remote — someone
# deleted it while the merge request was open, which leaves that merge request
# unmergeable until a human retargets it.
#
# Neither may be answered with the configuration's branch. Rebasing a merge
# request's branch onto a base GitLab is not diffing it against is the whole of
# this ticket, and doing it *because the real base is gone* would be the same
# damage under a better excuse. Autodev #89 settled the neighbouring case for the
# review skill the same way: abort, the line waits, never an invented verdict.
#
# It is an `ApiUnavailableError` on purpose, and not as a convenience: what the
# parent class encodes is "this unit of work cannot conclude, so nothing may be
# read off it" (Autodev #62), which is exactly the situation. Every boundary that
# already knows what to do with that — `MrFixer#fix` leaves the row in
# `fixing_discussions`, `PipelineMonitor#check` ends the poll with the row
# untouched and `abandon_expired_watch` unreached, `IssueProcessor#process` parks
# the row in `error` with a bounded retry because no pass re-enqueues an active
# state — keeps behaving correctly with no new rescue clause anywhere. The message
# says the truth rather than blaming an outage: `describe` is overridden, which is
# the one thing the parent exposes for it.
class MissingTargetBranchError < ApiUnavailableError
  attr_reader :branch, :detail

  def initialize(branch, detail)
    @branch = branch.to_s
    @detail = detail.to_s
    super(:target_branch, nil)
  end

  private

  def describe(_what, _error)
    named = @branch.empty? ? '(unnamed)' : "`#{@branch}`"
    "no base to rebase on: #{named} — #{@detail}"
  end
end

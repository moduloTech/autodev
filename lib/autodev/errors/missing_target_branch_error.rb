# frozen_string_literal: true

# A branch this work depends on could not be obtained (Autodev #91).
#
# Three ways in, one consequence. Either GitLab handed back a merge request that
# names no target branch; or the named branch is not on the remote — someone
# deleted it while the merge request was open, which leaves that merge request
# unmergeable until a human retargets it; or, since the review round, the ref that
# decides the project's review skill is not on the repository, which is the same
# fact one endpoint over and used to be reported as GitLab going dark.
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
# `confirmed` is what separates the two ways in, and it is the whole of the review
# round's answer to "this must be bounded and signalled" (constat 3). A base that
# is gone will never come back on its own, so a boundary is entitled to count the
# occurrence and, past `stagnation_threshold` of them, give the request up under a
# reason that names the cause. A base that could not be *established* — the fetch
# did not complete, the remote could not be asked — is an outage wearing the same
# exception, and counting it would abandon a healthy request over a flapping
# network. Only the first is `confirmed`, and only the first is counted; the
# second keeps the pre-existing behaviour exactly (abort, the row untouched, the
# next cycle re-reads).
#
# It defaults to false so that a new call site has to state its evidence in order
# to spend a budget.
class MissingTargetBranchError < ApiUnavailableError
  attr_reader :branch, :detail

  def initialize(branch, detail, confirmed: false)
    @branch = branch.to_s
    @detail = detail.to_s
    @confirmed = confirmed
    super(:target_branch, nil)
  end

  # True when something authoritative said the branch is not there — GitLab
  # describing a merge request that names none, or the remote itself answering
  # that it does not carry it.
  def confirmed? = @confirmed

  private

  def describe(_what, _error)
    named = @branch.empty? ? '(unnamed)' : "`#{@branch}`"
    "the branch #{named} is not available: #{@detail}"
  end
end

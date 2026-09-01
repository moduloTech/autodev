# frozen_string_literal: true

# GitLab answered, and the answer is that the request cannot succeed as it is
# formed (Autodev #95).
#
# This is the other half of the subject Autodev #62's third round settled in the
# opposite direction. That round widened `GitlabHelpers.answer` to cover the ways
# a call never completes — a reset socket, a timeout, a dead peer — because they
# are the *same event* as a 500 for every caller: nothing was read, come back next
# cycle. A 4xx is not that event. The call completed, GitLab parsed it, and it
# said no. Coming back next cycle with the identical request produces the
# identical answer, for ever.
#
# Measured on 01/09/2026, request powerpanne 15205: a merge request in conflict
# has no resolvable line codes, so every inline discussion `ReviewPublisher`
# tried to anchor came back `400 Bad request - Note {:line_code=>["can't be
# blank", "must be a valid line code"]}`. Read as an outage, the row went back to
# the watch having spent no counter, and the next poll paid for the whole skill
# review again — eighteen minutes of model time per cycle, close to 90% of a
# worker thread, bounded by nothing at all because the exception leaves
# `PipelineMonitor#check` before `abandon_expired_watch`.
#
# ## Why it is still an `ApiUnavailableError`
#
# For the reason `MissingTargetBranchError` is, and it is not a convenience. What
# the parent encodes is "this unit of work cannot conclude, so nothing may be read
# off it" (Autodev #62), and that is exactly the situation: `PipelineMonitor#check`
# ends the poll with the row untouched, `MrFixer#fix` leaves it in
# `fixing_discussions`, `IssueProcessor#process` parks it in `error` with a
# bounded retry. Every one of those keeps behaving correctly with no new rescue
# clause anywhere, and a sibling class would instead land in the generic
# `rescue StandardError` on one boundary and in *no* rescue on the other —
# ActiveJob, Solid Queue's failed executions, a human needed for something no
# cycle retries.
#
# What the family carries and this must not is the **waiting**. `describe` is
# overridden so the line an operator reads says what happened rather than blaming
# an outage, and `InvalidRequestBound` gives the request up after
# `stagnation_threshold` occurrences of the same refusal. Same division as #91:
# inherit the boundaries, refuse the wait.
#
# ## What counts as the same refusal
#
# `cause_signature`: the endpoint, the status and what GitLab said. A different
# endpoint, a different status or a different complaint is a different fact and
# restarts the count — the rule `MissingBaseBound` applies to the branch name and
# `StagnationDetector` to the failing job set.
class InvalidRequestError < ApiUnavailableError
  attr_reader :status, :detail

  def initialize(what, error, status)
    @status = status
    @detail = error.message.to_s
    super(what, error)
  end

  # Deliberately the whole message, GitLab's validation errors included: they are
  # what distinguishes one refusal from another, and a signature built on the
  # status alone would fold two unrelated causes into one count.
  def cause_signature = "#{what}|#{status}|#{detail}"

  private

  def describe(what, error)
    "GitLab refused the #{what} request as invalid (HTTP #{@status}): #{error.message}"
  end
end

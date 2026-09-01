# frozen_string_literal: true

require_relative 'consecutive_occurrences'

# What a boundary does with an `InvalidRequestError` (Autodev #95).
#
# The class documents why a request GitLab refused is a member of the
# `ApiUnavailableError` family: every boundary already knows how to end a unit of
# work that concluded nothing, and that is what this is. What it must not inherit
# is the **waiting** — the same split Autodev #91 had to make for a target branch
# the remote confirms it does not have, and for the same structural reason. An
# outage stops when the outage stops; a request GitLab refuses is refused
# identically for ever.
#
# Left as an outage, all four of the pipeline watch's guard-rails are down at
# once, and this is not a hypothesis: it is the production line of 01/09/2026.
#
#   * `PipelineMonitor#check` catches the family and logs;
#   * `abandon_expired_watch` is the last statement of `poll_open_mr`, so the
#     abort never reaches the absolute age bound;
#   * the review counters are deliberately untouched by a publication failure
#     (Autodev #62, #71), so nothing else was spending either;
#   * `log_pipeline_poll` collapses and `supersede!` moves `created_at` forward,
#     so `Issue.without_activity_since` keeps reading the row as fresh and
#     `DormantAudit` never sees it.
#
# Each of those is correct *for an outage*, so none of them is weakened. What
# changes is that this stopped being called one.
#
# ## What is counted
#
# `InvalidRequestError#cause_signature` — the endpoint, the status and what GitLab
# said. A different endpoint, a different status or a different complaint is a
# different fact and restarts the count, exactly as a different branch does in
# `MissingBaseBound` and a different failing job set in `StagnationDetector`. The
# bound is `stagnation_threshold`, the setting this repository already uses for
# "the same thing keeps happening and nothing is moving".
#
# The sequence counted is one of **occurrences, not of polls** — a cycle that
# refused nothing writes no occurrence, so it neither adds to the count nor clears
# it, and nothing empties `stagnation_signatures` outside a human re-arm. That is
# #91's behaviour and it is kept deliberately: five refusals of the same call are
# five refusals of the same call whenever they happened, and clearing the count on
# a healthy cycle would let a refusal that alternates with success cost a full
# review for ever, which is the expense this whole ticket exists to stop. What it
# does mean is that the number handed to a human is not "n polls in a row", so
# neither the comment nor the activity line says it is (neutral review, constat 3).
#
# There is no `confirmed?` flag here and there does not need to be one, which is
# the one place this differs from #91. `MissingTargetBranchError` was raised both
# by evidence and by an outage wearing the same exception, so the flag had to
# separate them; an `InvalidRequestError` is only ever built from GitLab's own
# 400/422, i.e. it is evidence by construction. Every other failure of the same
# call is an `ApiUnavailableError` and never reaches this module.
#
# ## The shape of the ending
#
# Autodev #81's, like #91's: the line stops, and it stops under a reason that
# names the cause. `abandon_issue` drives the three sinks (the GitLab comment, the
# activity line, the `/errors` explanation), poses `label_attention` and hands the
# ticket back to its author — who is the only person who can resolve the merge
# request's conflict, or whatever else made the call unacceptable.
#
# The reason is deliberately **not** a review failure. The review succeeded: it
# ran, it produced its findings, and `ReviewPublisher` even posted them in a
# summary comment when it could not anchor them. `review_failures_exhausted` would
# say something untrue on the ticket, and a visible chain does not lie (Autodev
# #63, #81, #85).
#
# And it is terminal. Nothing re-arms a `gitlab_refused_request` row:
# `dispatch_pipelines` selects `checking_pipeline`, `dispatch_discussions` selects
# `fixing_discussions`, `dispatch_done_unassigned` excludes flagged rows and
# `dispatch_infra_recheck` selects `stagnation_pipeline`. That is the property
# that makes rescuing this safe at all — a row handed back to the watch writes an
# activity line every cycle, which takes it out of `DormantAudit`'s active arm for
# ever and restamps the age clock (Autodev #74, #81).
#
# Expects `stagnation_threshold`, `abandon_issue`, `log`, `log_error`.
module InvalidRequestBound
  INVALID_REQUEST_KEY = 'invalid_request'
  # GitLab's own answer, on the ticket, in characters. Long enough for a
  # validation-error hash and the request URI the gem appends; short enough that a
  # runaway body cannot take a GitLab comment over.
  ANSWER_LIMIT = 400

  private

  # The one decision. Returns nothing a caller reads: the boundary that calls this
  # has already given up on the unit of work.
  def bound_invalid_request(issue, error)
    log_error "Issue ##{issue.issue_iid}: #{error.message}"
    count = ConsecutiveOccurrences.bump(issue, INVALID_REQUEST_KEY, error.cause_signature)
    return log_invalid_request_countdown(issue, error, count) if count < stagnation_threshold

    log "Issue ##{issue.issue_iid}: GitLab refused the #{error.what} request #{count} times → done"
    abandon_issue(issue, :gitlab_refused_request, what: error.what, status: error.status,
                                                  count: count, answer: refusal_answer(error))
  end

  def log_invalid_request_countdown(issue, error, count)
    log "Issue ##{issue.issue_iid}: GitLab refused the #{error.what} request " \
        "(#{count}/#{stagnation_threshold} occurrences of the same answer)"
  end

  # What GitLab actually said, quoted on the ticket (neutral review, constat 2).
  #
  # Nothing on this path reads `has_conflicts`, `merge_status` or
  # `detailed_merge_status` — `ReviewArrearsSweep` does, the two boundaries that
  # reach here do not — so the only cause autodev is entitled to name is the one
  # GitLab handed it. The three sinks used to supply one instead ("the commonest
  # cause is a merge request in conflict"), which was a guess printed on a client's
  # ticket, and a guess about a *review* under a diagnosis any refused endpoint
  # reaches: a refused `mr_discussions` read got the same sentence with no finding
  # in play at all.
  #
  # Adding the read instead was weighed and refused: it would put a GitLab call on
  # the give-up path, at the one moment GitLab is known to be refusing calls, and
  # its own failure would either escape the boundary rescue it is called from or
  # have to be swallowed. Quoting the answer costs nothing and is evidence.
  #
  # Scrubbed like every other diagnostic that reaches a sink (`Redactor`, Autodev
  # #49), and truncated with the truncation announced rather than silent.
  def refusal_answer(error)
    text = Redactor.scrub(error.detail.to_s.strip)
    return text if text.length <= ANSWER_LIMIT

    "#{text[0, ANSWER_LIMIT]}… (#{text.length - ANSWER_LIMIT} more characters)"
  end
end

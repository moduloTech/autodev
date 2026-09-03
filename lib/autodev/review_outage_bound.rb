# frozen_string_literal: true

# "The review could not be produced again, for the same reason" — the bound the
# alpha-53 neutral review (G3) put back after Autodev #107 removed the only one
# the binary path had.
#
# #107 was right that a review which could not run is not a verdict on the
# merge request, and it moved `:tool_unavailable` and `:clone_failed` off
# `review_failure_count` for that reason. What it left behind was a row that
# comes back to the watch on every poll with nothing bounding it but
# `pipeline_watch_max_days` — fourteen days — and then gives up under
# `pipeline_watch_expired`, a reason which says the watch stopped moving. For
# a `mr-review` binary that is not installed, or a source branch that no
# longer exists, that sentence is false and the wait is absurd: both are
# deterministic facts, known on the first poll.
#
# So the shape is #91's and #95's, not #107's: the cause is counted, and when
# the same cause has come back `stagnation_threshold` times the request stops
# under a reason that names it. `ConsecutiveOccurrences` owns the counting —
# this bound owns its keys, its threshold, its log lines and its two give-up
# reasons, the division `InvalidRequestBound` and `MissingBaseBound` already
# draw.
#
# ## Why nothing is written to the activity journal below the threshold
#
# This is the half of G3 that mattered most. `Reviewer` used to write an
# `ActivityEvent` on **every** poll of an outage, and `Issue.without_activity_since`
# — the clause common to all three of `DormantAudit`'s arms — excludes any row
# carrying an activity row after the cutoff. So for as long as the outage
# lasted, these rows left the safety net that Autodev #103 had just widened to
# catch exactly this kind of stranding. The file said so itself, five methods
# above, as its reason for *not* doing it (`Reviewer#launch_review`):
#
#   "Rescuing it *and resuming the watch* would write an activity row every
#    poll, which keeps the row out of `DormantAudit`'s active arm forever…"
#
# The countdown is therefore logged and not recorded, which is
# `WatchBound#log_bound_withheld`'s existing precedent for the same situation.
# The give-up itself does write to the journal — it happens once.
#
# ## What restarts the count
#
# The cause signature: which outcome, plus what the runner said. A different
# cause is a different fact and starts over, as everywhere else this module is
# used. The sequence is one of occurrences and not of polls — a cycle that
# reviewed fine writes nothing here, neither adding to the count nor clearing
# it — so the number must never be handed to a human as "n polls in a row",
# and neither sink says it is.
#
# Expects `stagnation_threshold`, `abandon_issue`, `log`, `log_error`.
module ReviewOutageBound
  REVIEW_OUTAGE_KEY = 'review_outage'

  # The give-up reason each non-spending cause ends under, once counted out.
  # `:inconclusive` is deliberately absent: GitLab not having computed
  # `diff_refs` yet is a fact about GitLab's clock, it costs no model time on
  # the binary path, and Autodev #74 chose the watch for it.
  OUTAGE_REASONS = {
    tool_unavailable: :review_tool_unavailable,
    clone_failed: :review_clone_failed
  }.freeze

  private

  # Returns `true` when the row was given up, `false` when the caller should
  # go on resuming the watch for another cycle.
  def bound_review_outage(issue, outcome, diagnostic = nil)
    reason = OUTAGE_REASONS[outcome]
    return false unless reason

    count = ConsecutiveOccurrences.bump(issue, REVIEW_OUTAGE_KEY, "#{outcome}:#{diagnostic}")
    return log_review_outage_countdown(issue, outcome, count) && false if count < stagnation_threshold

    log "Issue ##{issue.issue_iid}: the review could not be produced #{count} times " \
        "(#{outcome}) → done"
    abandon_issue(issue, reason, count: count)
    true
  end

  # Logged, never recorded: see the module comment. One line per poll in the
  # log is what an operator greps; one row per poll in the activity journal is
  # what takes the request out of `DormantAudit`.
  def log_review_outage_countdown(issue, outcome, count)
    log "Issue ##{issue.issue_iid}: review could not be produced (#{outcome}, " \
        "#{count}/#{stagnation_threshold} occurrences of the same cause) — " \
        'retrying next poll, no review budget spent'
  end
end

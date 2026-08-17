# frozen_string_literal: true

# The one definition of "does this merge request state carry a verdict".
#
# GitLab's merge request state machine declares exactly four states — `opened`,
# `closed`, `merged`, `locked` (`app/models/merge_request.rb`, `state_machine
# :state_id`, states + `lock_mr` / `unlock_mr` / `mark_as_merged` events). The
# GraphQL `MergeRequestState` enum adds only `all`, which is a filter value the
# API never returns for a single MR.
#
# `locked` is the only one of the four that carries no verdict.
# `MergeRequests::MergeService#execute` wraps the whole merge in
# `merge_request.in_locked_state`, so the state is entered from `opened` and left
# either for `merged` (the merge went through) or back for `opened` (it did not).
# GitLab's own REST reference says as much: "Searching by `locked` generally
# returns no results as that state is short-lived and transitional."
#
# It is an **allow-list** on purpose (Autodev #69). Anything GitLab adds tomorrow
# is *unknown*, not transitional, and every reader below keeps treating it as a
# verdict: erring towards "a human should look" is recoverable, erring towards
# "this is finished" is not.
#
# ## Why it lives here rather than in `PipelineMonitor` (Autodev #72)
#
# Autodev #69 put the list in one place precisely so that widening the door would
# be a decision and not an accident, and it put it in
# `PipelineMonitor::MrStateChecker` — a module of the pipeline monitor. Three of
# the four readers are not the pipeline monitor, and one of them is not even in
# `lib/`, so the list was out of reach and each reader answered the question
# again, differently:
#
#   * `PollRouter::ResumeHandler#reenter_destination` spelled `when 'locked' then
#     :wait` by hand — a second copy, free to diverge, the same shape Autodev #62
#     removed for `fetch_unresolved_discussions`;
#   * `PipelineMonitor::InfraRecheck#mr_open?` tested `== 'opened'`, so a `locked`
#     MR read as "not open" and **spent one of the `infra_recheck_max` attempts**
#     on an answer that meant "wait";
#   * `PollDispatcher#mr_closed_or_merged?` tested `%w[merged closed]`, so a
#     `locked` MR counted as neither — the opposite of the pipeline watch's sort —
#     and let the `post_completion` hook (a deploy) through while GitLab was
#     performing the merge.
#
# What is shared is this predicate and nothing else. The four readers ask
# different questions — was this delivered, does this need reimplementing, does
# this need re-arming, does this need deploying — and each keeps its own answer;
# uniformising the *decisions* would be a different and much worse ticket. What
# they may not disagree on is whether GitLab said anything at all.
#
# Four is the whole population, checked rather than assumed. The rest of the
# codebase reads a `state` field that is not a merge request's — `IssueProcessor`'s
# `issue_closed?` and `ExternalState`'s closed check read the *issue*'s
# (`opened` / `closed`, no transitional state to speak of) — with one deliberate
# exception: `DeployReviewSearch#related_open_iids` filters
# `related_merge_requests` down to the open ones. That is a list of candidates for
# a picker, not a verdict on one MR: dropping an MR that GitLab is merging costs a
# row in a search result that the next keystroke re-reads, and including it would
# offer a deploy-review button for a branch about to disappear.
module MrState
  TRANSIENT_STATES = %w[locked].freeze

  module_function

  # True when the state says "come back later" rather than naming an outcome.
  # Takes whatever `GitlabHelpers.field(mr, :state)` returned, symbol or nil
  # included: neither carries a verdict and neither may raise here.
  def transient?(state)
    TRANSIENT_STATES.include?(state.to_s)
  end
end

# frozen_string_literal: true

require_relative 'pipeline_monitor/constants'
require_relative 'pipeline_monitor/api_helpers'
require_relative 'pipeline_monitor/job_classifier'
require_relative 'pipeline_monitor/blocked_pipeline'
require_relative 'pipeline_monitor/evaluator'
require_relative 'pipeline_monitor/poll_tracker'
require_relative 'pipeline_monitor/post_completion'
require_relative 'pipeline_monitor/fix_prompts'
require_relative 'pipeline_monitor/failure_handler'
require_relative 'pipeline_monitor/infra_recheck'
require_relative 'pipeline_monitor/pipeline_fixer'
require_relative 'pipeline_monitor/reviewer'
require_relative 'pipeline_monitor/skill_reviewer'
require_relative 'pipeline_monitor/mr_state_checker'
require_relative 'pipeline_monitor/watch_bound'

# Monitors CI pipeline status and triages failures for tracked MRs.
class PipelineMonitor # rubocop:disable Metrics/ClassLength
  include DangerClaudeRunner
  include ApiHelpers
  include MrDiscussions
  include JobClassifier
  include BlockedPipeline
  include Evaluator
  include PollTracker
  include PostCompletion
  include FailureHandler
  include InfraRecheck
  include PipelineFixer
  include Reviewer
  include SkillReviewer
  include MrStateChecker
  include WatchBound
  include MissingBaseBound
  include InvalidRequestBound
  include StaleTransitionBound

  def initialize(client:, config:, project_config:, logger:, token:)
    init_runner(client: client, config: config, project_config: project_config, logger: logger, token: token)
  end

  def check(issue)
    begin_poll(issue)
    poll_open_mr(issue)
  # The boundary of one poll (Autodev #62). A read GitLab could not answer aborts
  # here with the row exactly as the previous cycle left it, and
  # `dispatch_pipelines` re-enqueues it next cycle. Note what the abort skips:
  # `abandon_expired_watch` is the last statement of `poll_open_mr`, so an API
  # error can no longer reach the age bound at all — which is the property
  # Autodev #56's spec claimed and Autodev #51 had quietly broken by rescuing the
  # error inside the fetch and returning a value.
  #
  # One clause for both errors because they are the same event: `ApiUnavailableError`
  # is a read whose failure was named at the call site, the bare
  # `Gitlab::Error::ResponseError` is one that was not (the `merge_request` read in
  # `poll_open_mr`). Neither concluded anything.
  #
  # The one member of the family that is **not** that event is caught above it: a
  # base the remote confirmed it does not have has nothing to come back from, so
  # waiting for it is a leak rather than a recovery — a full clone every cycle for
  # ever, with none of the four guard-rails this rescue relies on reachable. See
  # `MissingBaseBound` for what is counted and, above all, for what is not.
  rescue MissingTargetBranchError => e
    bound_missing_base(issue, e)
  # The second member of the family that is not that event, and the one this poll
  # met in production (Autodev #95): GitLab answered, and it said the request
  # cannot succeed as formed. Re-reading it next cycle produces the same answer,
  # so `InvalidRequestBound` counts the identical refusals and gives the request
  # up rather than paying for another eighteen-minute review to reach it again.
  rescue InvalidRequestError => e
    bound_invalid_request(issue, e)
  rescue ApiUnavailableError, Gitlab::Error::ResponseError => e
    log_error "Pipeline check for MR !#{issue.mr_iid} could not conclude: #{e.message}"
  rescue StandardError => e
    log_check_error(issue, e)
  end

  private

  # Everything one poll has to have done before it reads anything: the row it is
  # about, the per-poll verdict flag, the liveness line, and the watch clock — read
  # after `log_pipeline_poll` has seeded a NULL column and before any transition
  # can restamp it (see `remember_watch_clock`).
  def begin_poll(issue)
    @dc_issue = issue
    clear_poll_verdict
    log "Checking pipeline for MR !#{issue.mr_iid} (issue ##{issue.issue_iid})..."
    log_pipeline_poll(issue)
    remember_watch_clock(issue)
  end

  def poll_open_mr(issue)
    mr = @client.merge_request(@project_path, issue.mr_iid)
    return handle_mr_closed(issue, mr) if mr_state_concluded?(mr.state)

    continue_watch(issue, mr)
    # Last, and only if the poll left the row where it was: the absolute age
    # bound (Autodev #53) must never pre-empt a poll that resolved, and it must
    # cover every branch that goes nowhere without enumerating any of them —
    # including the ones Autodev #51 is currently rewriting.
    abandon_expired_watch(issue)
  end

  # The two MR states that keep the watch open, and the one thing they have in
  # common: the row is still `checking_pipeline` when this returns, so the age
  # bound above applies to both.
  #
  # That the transient states go through here rather than through an early return
  # is the whole point of Autodev #69's second half. Sorting `locked` as an
  # outcome was wrong, but sorting it as "come back later" and returning would have
  # traded a false abandon for an unbounded poll: `dispatch_pipelines` re-enqueues
  # every `checking_pipeline` row every cycle, and `abandon_expired_watch` is the
  # only thing standing at the end of that. An MR wedged in `locked` — GitLab's
  # `UnstickLockedMergeRequestsWorker` exists precisely because that happens — is
  # now given up at `pipeline_watch_max_days` like every other frozen watch.
  def continue_watch(issue, merge_request)
    state = merge_request.state
    return await_transient_mr_state(issue, state) unless state == 'opened'

    dispatch_pipeline(issue, merge_request.head_pipeline)
  end

  def dispatch_pipeline(issue, pipeline)
    return dispatch_status(issue, pipeline) if pipeline

    log "No pipeline found for MR !#{issue.mr_iid}, treating as green..."
    handle_green(issue)
  end

  def dispatch_status(issue, pipeline)
    status = GitlabHelpers.field(pipeline, :status)
    log "Pipeline ##{pipeline_id(pipeline)} status: #{status}"
    case status
    when *RUNNING_STATUSES then log "Pipeline still running for MR !#{issue.mr_iid}, skipping"
    when 'success'         then handle_green(issue)
    when 'failed'          then handle_red(issue, pipeline)
    when *BLOCKED_STATUSES then dispatch_blocked(issue, pipeline, status)
    # `canceled` and any future GitLab status land here: an interrupted run has
    # no verdict to read (its blocking jobs are `canceled`, not `failed`), and
    # unlike `manual` the wait usually resolves — a new pipeline supersedes it
    # and head_pipeline re-points. The unbounded tail is Autodev #53's job.
    else log "Pipeline #{status} for MR !#{issue.mr_iid}, skipping"
    end
  end

  # Claude-quota gate (Autodev #46). `:check_pipeline` keeps being dispatched
  # during an outage — tracking a pipeline costs no credit — but two branches
  # here do call Claude, so each checks the state the poll cycle probed.
  # Undefined outside Rails (CLI / unit tests): read as available, never gate by
  # omission.
  def claude_available?
    return true unless defined?(::Autodev::UsageGate)

    ::Autodev::UsageGate.available?
  end

  # Deliberately placed before `clear_pipeline_poll_since` and `log_activity`:
  # the ticket is still waiting, so the "checking pipeline" line stays as it is
  # rather than being replaced by a green line we can't act on — and a note
  # appended on every poll would blow past GitLab's 1M-char cap over a long
  # outage.
  def handle_green(issue)
    review_count = issue.review_count || 0
    return defer_review_for_usage(issue) if review_count.zero? && !claude_available?

    branch = green_branch(review_count)
    # Read before the two side effects below (Autodev #62). The post-review branch
    # needs the unresolved-thread list, and an unreadable one aborts the poll —
    # doing it first leaves the row exactly as the previous cycle left it, activity
    # note included, instead of appending one "pipeline green" line per cycle for
    # as long as the outage lasts (the growth Autodev #53 went to some trouble to
    # bound).
    discussions = branch == :post_review ? fetch_unresolved_discussions(issue.mr_iid) : nil
    clear_pipeline_poll_since(issue)
    log_activity(issue, :pipeline_green)
    dispatch_green(issue, branch, discussions)
  end

  # Named once so the read above and the dispatch below cannot disagree about
  # which branch this green pipeline is taking.
  def green_branch(review_count)
    return :review_limit if review_count >= Reviewer::MAX_REVIEW_ROUNDS
    return :first_review if review_count.zero?

    :post_review
  end

  def dispatch_green(issue, branch, discussions)
    case branch
    when :review_limit then green_done_max_reviews(issue)
    when :first_review then green_first_review(issue)
    else green_post_review(issue, discussions)
    end
  end

  # Both quota deferrals live here rather than in their own modules: they say
  # the same thing (the ticket stays in checking_pipeline, untouched, for the
  # next cycle) and belong next to the gate that triggers them.
  #
  # Each also marks the poll inconclusive (Autodev #56): the row is deliberately
  # left where it is because we could not act, not because the pipeline went
  # nowhere, so the age bound must not read it as a frozen watch. Without this a
  # pipeline that turned green on day 15 during a quota outage was abandoned with
  # a comment saying it had not moved for a fortnight.
  def defer_review_for_usage(issue)
    poll_inconclusive!(:claude_usage_exhausted)
    log "Issue ##{issue.issue_iid}: pipeline green but Claude usage exhausted, " \
        'deferring mr-review, staying in checking_pipeline'
  end

  def defer_fix_for_usage(issue)
    poll_inconclusive!(:claude_usage_exhausted)
    log "Issue ##{issue.issue_iid}: pipeline red but Claude usage exhausted, " \
        'deferring the fix, staying in checking_pipeline'
  end

  def green_first_review(issue)
    set_pipeline_green_guards(issue, review_count_zero: true)
    issue.pipeline_green!
    launch_review(issue)
  end

  # `discussions` is the list `handle_green` read from GitLab — never a substitute
  # for a failed read, which is what made `no_discussions` below a delivery
  # verdict taken on an outage (Autodev #62).
  def green_post_review(issue, discussions)
    snapshot(issue, :pre_fix_dispatch)
    set_pipeline_green_guards(issue, review_count_over_zero: true, no_discussions: discussions.empty?)
    issue.pipeline_green!
    finalize_green(issue, discussions)
  end

  def snapshot(issue, context)
    DiscussionSnapshot.capture(context: context, client: @client, project_path: @project_path,
                               mr_iid: issue.mr_iid, logger: @logger, issue: issue)
  end

  # Green, but `MAX_REVIEW_ROUNDS` rounds of review never resolved the
  # discussions: a give-up, not a delivery. Routed through the shared abandon
  # point since Autodev #60, which is also why `pipeline_green` no longer carries a
  # `max_review_rounds_reached?` transition to `done` — the state machine used to
  # offer two ways into `done` from `checking_pipeline`, one of them labelled
  # "green", which is exactly the divergence this ticket unpicked.
  def green_done_max_reviews(issue)
    log "Issue ##{issue.issue_iid}: max review rounds reached → done"
    abandon_issue(issue, :review_limit_reached)
  end

  def finalize_green(issue, discussions)
    return finalize_green_done(issue, discussions) if issue.done?

    log_activity(issue, :pipeline_green_discussions, count: discussions.size)
    log "Issue ##{issue.issue_iid}: pipeline green, #{discussions.size} discussion(s) → fixing_discussions"
  end

  def finalize_green_done(issue, discussions)
    iid = issue.issue_iid
    apply_label_done(iid)
    reassign_to_author(issue)
    Issue.where(id: issue.id).update_all(finished_at: Time.current)
    notify_localized(iid, :done_nominal, label_todo: @project_config['labels_todo']&.first)
    log_activity(issue, discussions.empty? ? :pipeline_green_done : :done, count: discussions.size)
    log "Issue ##{iid}: pipeline green, #{discussions.size} discussion(s) → done"
  end

  def set_pipeline_green_guards(issue, review_count_zero: false, review_count_over_zero: false,
                                no_discussions: true)
    issue._review_count_zero = review_count_zero
    issue._review_count_over_zero = review_count_over_zero
    issue._unresolved_discussions_empty = no_discussions
  end

  def log_check_error(issue, error)
    # This boundary only logs, but the line an operator reads must name the cause
    # rather than show a stack trace for something that is not a fault.
    return stop_on_stale_transition(error) if error.is_a?(StaleTransitionError)

    bt = error.backtrace&.first(5)&.join("\n  ")
    log_error "Pipeline check failed for issue ##{issue.issue_iid}: #{error.class}: #{error.message}"
    log_error "  #{bt}" if bt
  end
end

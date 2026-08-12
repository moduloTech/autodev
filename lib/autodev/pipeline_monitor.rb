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
require_relative 'pipeline_monitor/mr_state_checker'
require_relative 'pipeline_monitor/watch_bound'

# Monitors CI pipeline status and triages failures for tracked MRs.
class PipelineMonitor # rubocop:disable Metrics/ClassLength
  include DangerClaudeRunner
  include ApiHelpers
  include JobClassifier
  include BlockedPipeline
  include Evaluator
  include PollTracker
  include PostCompletion
  include FailureHandler
  include InfraRecheck
  include PipelineFixer
  include Reviewer
  include MrStateChecker
  include WatchBound

  def initialize(client:, config:, project_config:, logger:, token:)
    init_runner(client: client, config: config, project_config: project_config, logger: logger, token: token)
  end

  def check(issue)
    @dc_issue = issue
    log "Checking pipeline for MR !#{issue.mr_iid} (issue ##{issue.issue_iid})..."
    log_pipeline_poll(issue)
    poll_open_mr(issue)
  rescue Gitlab::Error::ResponseError => e
    log_error "Failed to check pipeline for MR !#{issue.mr_iid}: #{e.message}"
  rescue StandardError => e
    log_check_error(issue, e)
  end

  private

  def poll_open_mr(issue)
    mr = @client.merge_request(@project_path, issue.mr_iid)
    return handle_mr_closed(issue, mr) if mr.state != 'opened'

    dispatch_pipeline(issue, mr.head_pipeline)
    # Last, and only if the poll left the row where it was: the absolute age
    # bound (Autodev #53) must never pre-empt a poll that resolved, and it must
    # cover every branch that goes nowhere without enumerating any of them —
    # including the ones Autodev #51 is currently rewriting.
    abandon_expired_watch(issue)
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

    clear_pipeline_poll_since(issue)
    log_activity(issue, :pipeline_green)
    dispatch_green(issue, review_count)
  end

  def dispatch_green(issue, review_count)
    if review_count >= Reviewer::MAX_REVIEW_ROUNDS
      green_done_max_reviews(issue)
    elsif review_count.zero?
      green_first_review(issue)
    else
      green_post_review(issue)
    end
  end

  # Both quota deferrals live here rather than in their own modules: they say
  # the same thing (the ticket stays in checking_pipeline, untouched, for the
  # next cycle) and belong next to the gate that triggers them.
  def defer_review_for_usage(issue)
    log "Issue ##{issue.issue_iid}: pipeline green but Claude usage exhausted, " \
        'deferring mr-review, staying in checking_pipeline'
  end

  def defer_fix_for_usage(issue)
    log "Issue ##{issue.issue_iid}: pipeline red but Claude usage exhausted, " \
        'deferring the fix, staying in checking_pipeline'
  end

  def green_first_review(issue)
    set_pipeline_green_guards(issue, review_count_zero: true)
    issue.pipeline_green!
    launch_review(issue)
  end

  def green_post_review(issue)
    discussions = fetch_unresolved_discussions(issue.mr_iid)
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
    bt = error.backtrace&.first(5)&.join("\n  ")
    log_error "Pipeline check failed for issue ##{issue.issue_iid}: #{error.class}: #{error.message}"
    log_error "  #{bt}" if bt
  end
end

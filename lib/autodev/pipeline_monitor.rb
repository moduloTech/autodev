# frozen_string_literal: true

require_relative 'pipeline_monitor/constants'
require_relative 'pipeline_monitor/api_helpers'
require_relative 'pipeline_monitor/job_classifier'
require_relative 'pipeline_monitor/evaluator'
require_relative 'pipeline_monitor/poll_tracker'
require_relative 'pipeline_monitor/post_completion'
require_relative 'pipeline_monitor/fix_prompts'
require_relative 'pipeline_monitor/failure_handler'
require_relative 'pipeline_monitor/pipeline_fixer'
require_relative 'pipeline_monitor/reviewer'

# Monitors CI pipeline status and triages failures for tracked MRs.
class PipelineMonitor
  include DangerClaudeRunner
  include ApiHelpers
  include JobClassifier
  include Evaluator
  include PollTracker
  include PostCompletion
  include FailureHandler
  include PipelineFixer
  include Reviewer

  def initialize(client:, config:, project_config:, logger:, token:)
    init_runner(client: client, config: config, project_config: project_config, logger: logger, token: token)
  end

  def check(issue)
    log "Checking pipeline for MR !#{issue.mr_iid} (issue ##{issue.issue_iid})..."
    log_pipeline_poll(issue)
    pipeline = @client.merge_request(@project_path, issue.mr_iid).head_pipeline
    pipeline ? dispatch_status(issue, pipeline) : handle_no_pipeline(issue)
  rescue Gitlab::Error::ResponseError => e
    log_error "Failed to check pipeline for MR !#{issue.mr_iid}: #{e.message}"
  rescue StandardError => e
    log_check_error(issue, e)
  end

  def handle_no_pipeline(issue)
    log "No pipeline found for MR !#{issue.mr_iid}, treating as green..."
    handle_green(issue)
  end

  RUNNING_STATUSES = %w[running pending created waiting_for_resource preparing scheduled].freeze

  private

  def dispatch_status(issue, pipeline)
    status = pipeline.respond_to?(:status) ? pipeline.status : pipeline['status']
    log "Pipeline ##{pipeline_id(pipeline)} status: #{status}"
    case status
    when *RUNNING_STATUSES then log "Pipeline still running for MR !#{issue.mr_iid}, skipping"
    when 'success'         then handle_green(issue)
    when 'failed'          then handle_red(issue, pipeline)
    else log "Pipeline #{status} for MR !#{issue.mr_iid}, skipping"
    end
  end

  def handle_green(issue)
    clear_pipeline_poll_since(issue)
    log_activity(issue, :pipeline_green)
    review_count = issue.review_count || 0

    if review_count >= Reviewer::MAX_REVIEW_ROUNDS
      green_done_max_reviews(issue)
    elsif review_count.zero?
      green_first_review(issue)
    else
      green_post_review(issue)
    end
  end

  def green_first_review(issue)
    set_pipeline_green_guards(issue, review_count_zero: true)
    issue.pipeline_green!
    launch_review(issue)
  end

  def green_post_review(issue)
    discussions = fetch_unresolved_discussions(issue.mr_iid)
    set_pipeline_green_guards(issue, review_count_over_zero: true, no_discussions: discussions.empty?)
    issue.pipeline_green!
    finalize_green(issue, discussions)
  end

  def green_done_max_reviews(issue)
    set_pipeline_green_guards(issue, max_review_rounds: true)
    issue.pipeline_green!
    apply_label_mr(issue.issue_iid)
    reassign_to_author(issue)
    Issue.where(id: issue.id).update(finished_at: Sequel.lit("datetime('now')"))
    notify_localized(issue.issue_iid, :review_limit_reached, mr_url: issue.mr_url)
    log_activity(issue, :review_limit_reached)
    log "Issue ##{issue.issue_iid}: max review rounds reached → done"
  end

  def finalize_green(issue, discussions)
    return finalize_green_done(issue, discussions) if issue.done?

    log_activity(issue, :pipeline_green_discussions, count: discussions.size)
    log "Issue ##{issue.issue_iid}: pipeline green, #{discussions.size} discussion(s) → fixing_discussions"
  end

  def finalize_green_done(issue, discussions)
    apply_label_mr(issue.issue_iid)
    reassign_to_author(issue)
    Issue.where(id: issue.id).update(finished_at: Sequel.lit("datetime('now')"))
    log_activity(issue, discussions.empty? ? :pipeline_green_done : :done, count: discussions.size)
    log "Issue ##{issue.issue_iid}: pipeline green, no discussions → done"
  end

  def set_pipeline_green_guards(issue, review_count_zero: false, review_count_over_zero: false,
                                max_review_rounds: false, no_discussions: true)
    issue._review_count_zero = review_count_zero
    issue._review_count_over_zero = review_count_over_zero
    issue._max_review_rounds_reached = max_review_rounds
    issue._unresolved_discussions_empty = no_discussions
  end

  def log_check_error(issue, error)
    bt = error.backtrace&.first(5)&.join("\n  ")
    log_error "Pipeline check failed for issue ##{issue.issue_iid}: #{error.class}: #{error.message}"
    log_error "  #{bt}" if bt
  end
end

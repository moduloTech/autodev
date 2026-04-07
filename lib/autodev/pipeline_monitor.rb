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

  def initialize(client:, config:, project_config:, logger:, token:)
    init_runner(client: client, config: config, project_config: project_config, logger: logger, token: token)
  end

  def check(issue)
    max_fix = (@project_config['max_fix_rounds'] || @config['max_fix_rounds']).to_i
    log "Checking pipeline for MR !#{issue.mr_iid} (issue ##{issue.issue_iid})..."
    log_pipeline_poll(issue)
    pipeline = @client.merge_request(@project_path, issue.mr_iid).head_pipeline
    pipeline ? dispatch_status(issue, pipeline, max_fix) : handle_no_pipeline(issue, max_fix)
  rescue Gitlab::Error::ResponseError => e
    log_error "Failed to check pipeline for MR !#{issue.mr_iid}: #{e.message}"
  rescue StandardError => e
    log_check_error(issue, e)
  end

  def handle_no_pipeline(issue, max_fix)
    log "No pipeline found for MR !#{issue.mr_iid}, checking conversations..."
    handle_green(issue, max_fix)
  end

  private

  def dispatch_status(issue, pipeline, max_fix)
    status = pipeline.respond_to?(:status) ? pipeline.status : pipeline['status']
    log "Pipeline ##{pipeline_id(pipeline)} status: #{status}"

    case status
    when 'running', 'pending', 'created', 'waiting_for_resource', 'preparing', 'scheduled'
      log "Pipeline still running for MR !#{issue.mr_iid}, skipping"
    when 'success'  then handle_green(issue, max_fix)
    when 'failed'   then handle_red(issue, pipeline, max_fix)
    when 'canceled', 'skipped' then handle_canceled(issue, status)
    else log "Unknown pipeline status '#{status}' for MR !#{issue.mr_iid}, skipping"
    end
  end

  def handle_canceled(issue, status)
    log "Pipeline #{status} for MR !#{issue.mr_iid}"
    clear_pipeline_poll_since(issue)
    issue.pipeline_canceled!
    apply_label_blocked(issue.issue_iid)
    notify_localized(issue.issue_iid, :pipeline_canceled, mr_url: issue.mr_url, status: status)
    log_activity(issue, :pipeline_canceled, status: status)
  end

  def handle_green(issue, max_fix_rounds)
    discussions = fetch_unresolved_discussions(issue.mr_iid)
    set_green_guards(issue, discussions, max_fix_rounds)
    clear_pipeline_poll_since(issue)
    log_activity(issue, :pipeline_green)
    issue.pipeline_green!
    complete_green(issue, discussions)
  end

  def set_green_guards(issue, discussions, max_fix_rounds)
    pc_cmd = @project_config['post_completion']
    issue._unresolved_discussions_empty = discussions.empty?
    issue._max_fix_rounds = max_fix_rounds
    issue._post_completion = pc_cmd.is_a?(Array) && pc_cmd.any?
  end

  def complete_green(issue, discussions)
    run_post_completion_if_needed(issue)
    log_green_activity(issue, discussions)
    log_green(issue, discussions)
  end

  def run_post_completion_if_needed(issue)
    return unless issue.running_post_completion?

    log_activity(issue, :post_completion)
    run_post_completion(issue, @project_config['post_completion'])
    issue.post_completion_done!
  end

  def log_green_activity(issue, discussions)
    if issue.over?
      reassign_to_author(issue)
      log_activity(issue, discussions.empty? ? :pipeline_green_over : :over, count: discussions.size)
    else
      log_activity(issue, :pipeline_green_discussions, count: discussions.size)
    end
  end

  def log_green(issue, discussions)
    iid = issue.issue_iid
    unless issue.over?
      return log("Issue ##{iid}: pipeline green, #{discussions.size} conversation(s) → fixing_discussions")
    end

    msg = discussions.empty? ? 'no open conversations' : 'conversations but max rounds reached'
    log "Issue ##{iid}: pipeline green, #{msg} → over"
  end

  def log_check_error(issue, error)
    bt = error.backtrace&.first(5)&.join("\n  ")
    log_error "Pipeline check failed for issue ##{issue.issue_iid}: #{error.class}: #{error.message}"
    log_error "  #{bt}" if bt
  end
end

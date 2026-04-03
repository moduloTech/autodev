# frozen_string_literal: true

require_relative 'pipeline_monitor/constants'
require_relative 'pipeline_monitor/api_helpers'
require_relative 'pipeline_monitor/job_classifier'
require_relative 'pipeline_monitor/post_completion'
require_relative 'pipeline_monitor/failure_handler'
require_relative 'pipeline_monitor/pipeline_fixer'

# Monitors CI pipeline status and triages failures for tracked MRs.
class PipelineMonitor
  include DangerClaudeRunner
  include ApiHelpers
  include JobClassifier
  include PostCompletion
  include FailureHandler
  include PipelineFixer

  def initialize(client:, config:, project_config:, logger:, token:)
    init_runner(client: client, config: config, project_config: project_config, logger: logger, token: token)
  end

  def check(issue)
    max_fix = (@project_config['max_fix_rounds'] || @config['max_fix_rounds']).to_i
    log "Checking pipeline for MR !#{issue.mr_iid} (issue ##{issue.issue_iid})..."
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
    issue.pipeline_canceled!
    apply_label_blocked(issue.issue_iid)
    notify_localized(issue.issue_iid, :pipeline_canceled, mr_url: issue.mr_url, status: status)
  end

  def handle_green(issue, max_fix_rounds)
    discussions = fetch_unresolved_discussions(issue.mr_iid)
    set_green_guards(issue, discussions, max_fix_rounds)
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
    if issue.running_post_completion?
      run_post_completion(issue, @project_config['post_completion'])
      issue.post_completion_done!
    end
    reassign_to_author(issue) if issue.over?
    log_green(issue, discussions)
  end

  def log_green(issue, discussions)
    iid = issue.issue_iid
    unless issue.over?
      return log("Issue ##{iid}: pipeline green, #{discussions.size} conversation(s) → fixing_discussions")
    end

    msg = discussions.empty? ? 'no open conversations' : 'conversations but max rounds reached'
    log "Issue ##{iid}: pipeline green, #{msg} → over"
  end

  def evaluate_code_related(work_dir, eval_context)
    prompt = build_eval_prompt(eval_context)
    out = danger_claude_prompt(work_dir, prompt, label: '-p (pipeline eval)')
    parse_eval_response(out)
  end

  def build_eval_prompt(eval_context)
    <<~PROMPT
      Tu dois analyser un echec de pipeline CI/CD et determiner s'il est lie au code ou non.

      ## Jobs en echec

      #{eval_context}

      Lis chaque fichier de log reference ci-dessus.

      ## Instructions de reponse

      Reponds UNIQUEMENT avec un objet JSON valide (sans bloc de code markdown) :
      { "code_related": true/false, "explanation": "explication courte" }

      - `code_related: true` si l'echec vient du code (test, compilation, lint, etc.)
      - `code_related: false` si infrastructure (timeout reseau, service indisponible, quota, etc.)
    PROMPT
  end

  def parse_eval_response(out)
    json_match = out.match(/\{[^{}]*"code_related"\s*:\s*(true|false)[^{}]*\}/m)
    return nil unless json_match

    JSON.parse(json_match[0])
  rescue JSON::ParserError
    nil
  end

  def log_check_error(issue, error)
    bt = error.backtrace&.first(5)&.join("\n  ")
    log_error "Pipeline check failed for issue ##{issue.issue_iid}: #{error.class}: #{error.message}"
    log_error "  #{bt}" if bt
  end
end

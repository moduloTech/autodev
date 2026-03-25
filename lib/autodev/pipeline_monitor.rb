# frozen_string_literal: true

class PipelineMonitor
  include DangerClaudeRunner

  def initialize(client:, config:, project_config:, logger:, token:)
    init_runner(client: client, config: config, project_config: project_config, logger: logger, token: token)
  end

  def check(issue)
    iid    = issue.issue_iid
    mr_iid = issue.mr_iid
    max_fix_rounds = (@project_config["max_fix_rounds"] || @config["max_fix_rounds"]).to_i

    log "Checking pipeline for MR !#{mr_iid} (issue ##{iid})..."

    mr = @client.merge_request(@project_path, mr_iid)
    pipeline = mr.head_pipeline

    unless pipeline
      log "No pipeline found for MR !#{mr_iid}, checking conversations..."
      handle_green(issue, max_fix_rounds)
      return
    end

    status = pipeline.respond_to?(:status) ? pipeline.status : pipeline["status"]
    log "Pipeline ##{pipeline_id(pipeline)} status: #{status}"

    case status
    when "running", "pending", "created", "waiting_for_resource", "preparing", "scheduled"
      log "Pipeline still running for MR !#{mr_iid}, skipping"
    when "success"
      handle_green(issue, max_fix_rounds)
    when "failed"
      handle_red(issue, pipeline, max_fix_rounds)
    when "canceled", "skipped"
      log "Pipeline #{status} for MR !#{mr_iid}"
      issue.pipeline_canceled!
      notify_issue(iid, ":warning: **autodev** : le pipeline de #{issue.mr_url} est #{status}. Intervention manuelle requise.")
      log "Issue ##{iid}: pipeline #{status} → blocked"
    else
      log "Unknown pipeline status '#{status}' for MR !#{mr_iid}, skipping"
    end
  rescue Gitlab::Error::ResponseError => e
    log_error "Failed to check pipeline for MR !#{mr_iid}: #{e.message}"
  rescue StandardError => e
    bt = e.backtrace&.first(5)&.join("\n  ")
    log_error "Pipeline check failed for issue ##{issue.issue_iid}: #{e.class}: #{e.message}"
    log_error "  #{bt}" if bt
  end

  private

  def handle_green(issue, max_fix_rounds)
    iid    = issue.issue_iid
    mr_iid = issue.mr_iid

    discussions = fetch_unresolved_discussions(mr_iid)
    issue._unresolved_discussions_empty = discussions.empty?
    issue._max_fix_rounds = max_fix_rounds
    issue.pipeline_green! # → over or fixing_discussions (via guards)

    if issue.over?
      if discussions.empty?
        log "Issue ##{iid}: pipeline green, no open conversations → over"
      else
        log "Issue ##{iid}: pipeline green, #{discussions.size} conversation(s) but max fix rounds reached → over"
      end
    else
      log "Issue ##{iid}: pipeline green, #{discussions.size} unresolved conversation(s) → fixing_discussions"
    end
  end

  def handle_red(issue, pipeline, max_fix_rounds)
    iid    = issue.issue_iid
    mr_iid = issue.mr_iid
    retrigger_count = issue.pipeline_retrigger_count || 0

    if retrigger_count < 1
      log "Pipeline failed for MR !#{mr_iid}, retriggering (attempt #{retrigger_count + 1})..."
      begin
        @client.retry_pipeline(@project_path, pipeline_id(pipeline))
        issue.update(pipeline_retrigger_count: retrigger_count + 1)
        log "Pipeline retriggered for MR !#{mr_iid}"
      rescue Gitlab::Error::ResponseError => e
        log_error "Failed to retrigger pipeline: #{e.message}"
        evaluate_failure(issue, pipeline, max_fix_rounds)
      end
    else
      evaluate_failure(issue, pipeline, max_fix_rounds)
    end
  end

  def evaluate_failure(issue, pipeline, max_fix_rounds)
    iid = issue.issue_iid

    failed_jobs = fetch_failed_jobs(pipeline)
    if failed_jobs.empty?
      log "No failed jobs found for pipeline ##{pipeline_id(pipeline)}, marking as blocked"
      issue.pipeline_failed_infra!
      notify_issue(iid, ":warning: **autodev** : le pipeline de #{issue.mr_url} a echoue mais aucun job en echec n'a ete trouve. Intervention manuelle requise.")
      return
    end

    job_context = build_job_context(failed_jobs)
    work_dir = "/tmp/autodev_pipeline_#{@project_path.gsub("/", "_")}_#{iid}"
    begin
      clone_and_checkout(work_dir, issue.branch_name)

      eval_result = evaluate_code_related(work_dir, job_context)

      unless eval_result
        log "Could not parse pipeline evaluation response, marking as blocked"
        issue.pipeline_failed_infra!
        notify_issue(iid, ":warning: **autodev** : le pipeline de #{issue.mr_url} a echoue et l'evaluation automatique n'a pas abouti. Intervention manuelle requise.")
        return
      end

      explanation = eval_result["explanation"] || "Aucune explication fournie"

      unless eval_result["code_related"]
        issue.pipeline_failed_infra!
        notify_issue(iid, ":warning: **autodev** : le pipeline de #{issue.mr_url} echoue pour une raison hors code. Intervention manuelle requise.\n\n> #{explanation}")
        log "Issue ##{iid}: non-code pipeline failure → blocked (#{explanation})"
        return
      end

      # Code-related — fire event (guard decides fixing_pipeline vs blocked)
      issue._max_fix_rounds = max_fix_rounds
      issue.pipeline_failed_code!

      if issue.blocked?
        notify_issue(iid, ":warning: **autodev** : le pipeline de #{issue.mr_url} echoue a cause du code mais le nombre maximum de rounds de fix est atteint. Intervention manuelle requise.\n\n> #{explanation}")
        log "Issue ##{iid}: code-related pipeline failure but max fix rounds reached → blocked"
        return
      end

      # Fix the code
      log "Issue ##{iid}: code-related pipeline failure, fixing... (#{explanation})"
      fix_pipeline_failure(work_dir, job_context, issue)

    rescue StandardError => e
      bt = e.backtrace&.first(10)&.join("\n  ")
      log_error "Pipeline evaluation/fix failed: #{e.class}: #{e.message}"
      log_error "  #{bt}" if bt
      begin
        issue.mark_failed!
      rescue AASM::InvalidTransition
        issue.update(status: "error")
      end
      issue.update(error_message: "Pipeline fix error: #{e.class}: #{e.message}\n  #{bt}",
                   dc_stdout: @dc_stdout, dc_stderr: @dc_stderr)
      notify_issue(iid, ":x: **autodev** : echec de la correction du pipeline — #{e.class}: #{e.message[0, 200]}")
    ensure
      FileUtils.rm_rf(work_dir) if work_dir && Dir.exist?(work_dir)
    end
  end

  def build_job_context(failed_jobs)
    failed_jobs.map do |job|
      name = job.respond_to?(:name) ? job.name : job["name"]
      stage = job.respond_to?(:stage) ? job.stage : job["stage"]
      trace = fetch_job_trace(job)
      "### Job: #{name} (stage: #{stage})\n\n```\n#{trace}\n```"
    end.join("\n\n")
  end

  def evaluate_code_related(work_dir, job_context)
    prompt = <<~PROMPT
      Tu dois analyser un echec de pipeline CI/CD sur une Merge Request et determiner s'il est lie au code ou non.

      ## Jobs en echec

      #{job_context}

      ## Instructions de reponse

      Reponds UNIQUEMENT avec un objet JSON valide (sans bloc de code markdown), avec cette structure :
      {
        "code_related": true/false,
        "explanation": "explication courte de la cause"
      }

      - `code_related: true` si l'echec vient du code (test qui echoue, erreur de compilation, lint, etc.)
      - `code_related: false` si l'echec vient de l'infrastructure (timeout reseau, service indisponible, quota, permission, image Docker introuvable, etc.)
      - Sois pragmatique dans ton evaluation
    PROMPT

    out = danger_claude_prompt(work_dir, prompt, label: "-p (pipeline eval)")
    json_match = out.match(/\{[^{}]*"code_related"\s*:\s*(true|false)[^{}]*\}/m)
    return nil unless json_match

    JSON.parse(json_match[0])
  rescue JSON::ParserError
    nil
  end

  def fix_pipeline_failure(work_dir, job_context, issue)
    iid       = issue.issue_iid
    branch    = issue.branch_name
    fix_round = issue.fix_round

    extra = @project_config["extra_prompt"]
    prompt = <<~PROMPT
      Tu dois corriger le code pour resoudre un echec de pipeline CI/CD.

      ## Jobs en echec

      #{job_context}

      ## Instructions

      - Analyse les logs des jobs en echec ci-dessus.
      - Corrige le code source pour que ces jobs passent au vert.
      - Respecte les conventions du projet (voir CLAUDE.md si present).
      - Ne modifie que ce qui est necessaire pour corriger les erreurs de pipeline.
      - Ne touche pas aux fichiers de configuration CI/CD sauf si c'est la cause directe de l'echec.
      #{extra ? "\n## Instructions supplementaires du projet\n\n#{extra}" : ""}
    PROMPT

    danger_claude_prompt(work_dir, prompt, label: "-p (pipeline fix)")
    danger_claude_commit(work_dir, label: "-c (pipeline fix)")

    _out, _err, ok = run_cmd_status(["git", "log", "origin/#{branch}..HEAD", "--oneline"], chdir: work_dir)
    unless ok
      log "No new commits after pipeline fix, skipping push"
      issue.update(fix_round: fix_round + 1, pipeline_retrigger_count: 0)
      issue.pipeline_fix_done!
      return
    end

    log "Pushing pipeline fix to #{branch}..."
    _out, _err, push_ok = run_cmd_status(["git", "push", "origin", branch], chdir: work_dir)
    unless push_ok
      log "Push failed, retrying with --force-with-lease..."
      run_cmd(["git", "push", "--force-with-lease", "origin", branch], chdir: work_dir)
    end

    issue.update(fix_round: fix_round + 1, pipeline_retrigger_count: 0,
                 dc_stdout: @dc_stdout, dc_stderr: @dc_stderr)
    issue.pipeline_fix_done! # fixing_pipeline → checking_pipeline
    notify_issue(iid, ":wrench: **autodev** : correction du pipeline appliquee sur #{issue.mr_url} (round #{fix_round + 1})")
    log "Issue ##{iid}: pipeline fix pushed (round #{fix_round + 1})"
  end

  def fetch_failed_jobs(pipeline)
    pid = pipeline_id(pipeline)
    jobs = @client.pipeline_jobs(@project_path, pid, per_page: 100)
    jobs.select do |j|
      status = j.respond_to?(:status) ? j.status : j["status"]
      status == "failed"
    end
  rescue Gitlab::Error::ResponseError => e
    log_error "Failed to fetch pipeline jobs: #{e.message}"
    []
  end

  def fetch_job_trace(job)
    jid = job.respond_to?(:id) ? job.id : job["id"]
    trace = @client.job_trace(@project_path, jid)
    trace = trace.to_s
    trace.length > 3000 ? trace[-3000..] : trace
  rescue Gitlab::Error::ResponseError => e
    log_error "Failed to fetch job trace: #{e.message}"
    "(trace unavailable: #{e.message})"
  end

  def fetch_unresolved_discussions(mr_iid)
    discussions = @client.merge_request_discussions(@project_path, mr_iid)
    discussions.select { |d| d.notes&.any? && !resolved?(d) }
  rescue Gitlab::Error::ResponseError => e
    log_error "Failed to fetch MR discussions: #{e.message}"
    []
  end

  def resolved?(discussion)
    resolvable_notes = discussion.notes.select { |n| n.respond_to?(:resolvable) && n.resolvable }
    return true if resolvable_notes.empty?
    resolvable_notes.all? { |n| n.respond_to?(:resolved) && n.resolved }
  end

  def pipeline_id(pipeline)
    pipeline.respond_to?(:id) ? pipeline.id : pipeline["id"]
  end
end

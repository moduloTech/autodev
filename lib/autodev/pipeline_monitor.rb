# frozen_string_literal: true

# Monitors CI pipeline status and triages failures for tracked MRs.
class PipelineMonitor
  include DangerClaudeRunner

  def initialize(client:, config:, project_config:, logger:, token:)
    init_runner(client: client, config: config, project_config: project_config, logger: logger, token: token)
  end

  def check(issue)
    iid    = issue.issue_iid
    mr_iid = issue.mr_iid
    max_fix_rounds = (@project_config['max_fix_rounds'] || @config['max_fix_rounds']).to_i

    log "Checking pipeline for MR !#{mr_iid} (issue ##{iid})..."

    mr = @client.merge_request(@project_path, mr_iid)
    pipeline = mr.head_pipeline

    unless pipeline
      log "No pipeline found for MR !#{mr_iid}, checking conversations..."
      handle_green(issue, max_fix_rounds)
      return
    end

    status = pipeline.respond_to?(:status) ? pipeline.status : pipeline['status']
    log "Pipeline ##{pipeline_id(pipeline)} status: #{status}"

    case status
    when 'running', 'pending', 'created', 'waiting_for_resource', 'preparing', 'scheduled'
      log "Pipeline still running for MR !#{mr_iid}, skipping"
    when 'success'
      handle_green(issue, max_fix_rounds)
    when 'failed'
      handle_red(issue, pipeline, max_fix_rounds)
    when 'canceled', 'skipped'
      log "Pipeline #{status} for MR !#{mr_iid}"
      issue.pipeline_canceled!
      set_label_blocked(iid)
      notify_localized(iid, :pipeline_canceled, mr_url: issue.mr_url, status: status)
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

    post_completion_cmd = @project_config['post_completion']
    issue._has_post_completion = post_completion_cmd.is_a?(Array) && post_completion_cmd.any?

    issue.pipeline_green! # → running_post_completion, over, or fixing_discussions (via guards)

    if issue.running_post_completion?
      run_post_completion(issue, post_completion_cmd)
      issue.post_completion_done! # running_post_completion → over
      reassign_to_author(issue)
      log "Issue ##{iid}: pipeline green, post_completion executed → over"
    elsif issue.over?
      reassign_to_author(issue)
      if discussions.empty?
        log "Issue ##{iid}: pipeline green, no open conversations → over"
      else
        log "Issue ##{iid}: pipeline green, #{discussions.size} conversation(s) but max fix rounds reached → over"
      end
    else
      log "Issue ##{iid}: pipeline green, #{discussions.size} unresolved conversation(s) → fixing_discussions"
    end
  end

  # Runs a project-configured post_completion command in a temporary clone.
  # Non-fatal: errors are logged and stored but do not prevent transition to over.
  def run_post_completion(issue, cmd)
    iid = issue.issue_iid

    unless cmd.is_a?(Array) && cmd.all?(String)
      error_msg = "post_completion config must be an array of strings, got: #{cmd.inspect}"
      log_error "Issue ##{iid}: #{error_msg}"
      Issue.where(id: issue.id).update(post_completion_error: error_msg)
      return
    end

    log "Running post_completion for issue ##{iid}: #{cmd.inspect}"

    work_dir = "/tmp/autodev_post_completion_#{@project_path.gsub('/', '_')}_#{iid}"
    begin
      clone_and_checkout(work_dir, issue.branch_name)

      env = CLEAN_ENV.merge(
        'AUTODEV_ISSUE_IID' => issue.issue_iid.to_s,
        'AUTODEV_MR_IID' => issue.mr_iid.to_s,
        'AUTODEV_BRANCH_NAME' => issue.branch_name.to_s
      )

      timeout = (@project_config['post_completion_timeout'] || 300).to_i

      stdout_r, stdout_w = IO.pipe
      stderr_r, stderr_w = IO.pipe

      pid = Process.spawn(env, *cmd, chdir: work_dir, in: :close, out: stdout_w, err: stderr_w, pgroup: true)
      stdout_w.close
      stderr_w.close

      out_thread = Thread.new { stdout_r.read }
      err_thread = Thread.new { stderr_r.read }

      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        if remaining <= 0
          Process.kill('TERM', -pid)
          sleep 3
          begin
            Process.kill('KILL', -pid)
          rescue StandardError
            nil
          end
          begin
            Process.wait(pid)
          rescue StandardError
            nil
          end
          out = out_thread.value
          err = err_thread.value
          error_msg = "post_completion timed out after #{timeout}s\nstdout: #{out[0, 1000]}\nstderr: #{err[0, 1000]}"
          log_error "Issue ##{iid}: #{error_msg}"
          Issue.where(id: issue.id).update(post_completion_error: error_msg)
          return
        end

        _pid, status = Process.wait2(pid, Process::WNOHANG)
        if status
          out = out_thread.value
          err = err_thread.value
          if status.success?
            log "Issue ##{iid}: post_completion succeeded"
          else
            error_msg = "post_completion exited #{status.exitstatus}\nstdout: #{out[0, 1000]}\nstderr: #{err[0, 1000]}"
            log_error "Issue ##{iid}: #{error_msg}"
            Issue.where(id: issue.id).update(post_completion_error: error_msg)
          end
          return
        end

        sleep 1
      end
    ensure
      stdout_r&.close
      stderr_r&.close
      FileUtils.rm_rf(work_dir) if work_dir && Dir.exist?(work_dir)
    end
  end

  def handle_red(issue, pipeline, max_fix_rounds)
    evaluate_failure(issue, pipeline, max_fix_rounds)
  end

  def evaluate_failure(issue, pipeline, max_fix_rounds)
    iid    = issue.issue_iid
    mr_iid = issue.mr_iid

    failed_jobs = fetch_failed_jobs(pipeline)
    if failed_jobs.empty?
      log "No failed jobs found for pipeline ##{pipeline_id(pipeline)}, marking as blocked"
      issue.pipeline_failed_infra!
      set_label_blocked(iid)
      notify_localized(iid, :pipeline_no_failed_jobs, mr_url: issue.mr_url)
      return
    end

    # --- Phase 1: pre-triage using failure_reason (no clone, no Claude) ---

    triage = pre_triage(failed_jobs)

    if triage[:verdict] != :code
      # Infra or uncertain: retrigger once before escalating
      retrigger_count = issue.pipeline_retrigger_count || 0
      if retrigger_count < 1
        log "Pipeline failed for MR !#{mr_iid} (pre-triage: #{triage[:verdict]}), retriggering (attempt #{retrigger_count + 1})..."
        begin
          @client.retry_pipeline(@project_path, pipeline_id(pipeline))
          issue.update(pipeline_retrigger_count: retrigger_count + 1)
          log "Pipeline retriggered for MR !#{mr_iid}"
          return
        rescue Gitlab::Error::ResponseError => e
          log_error "Failed to retrigger pipeline: #{e.message}"
        end
      end
    end

    if triage[:verdict] == :infra
      issue.pipeline_failed_infra!
      set_label_blocked(iid)
      notify_localized(iid, :pipeline_infra_pretriage, mr_url: issue.mr_url, explanation: triage[:explanation])
      log "Issue ##{iid}: infra failure detected by pre-triage → blocked (#{triage[:explanation]})"
      return
    end

    # --- Phase 2: clone + write logs (needed for fix and possibly Claude eval) ---

    work_dir = "/tmp/autodev_pipeline_#{@project_path.gsub('/', '_')}_#{iid}"
    begin
      clone_and_checkout(work_dir, issue.branch_name)
      skills_result = SkillsInjector.inject(work_dir, logger: @logger, project_path: @project_path)
      @all_skills = skills_result[:all_skills]

      log_dir = File.join(work_dir, 'tmp', 'ci_logs')
      FileUtils.mkdir_p(log_dir)
      job_entries = write_job_logs(failed_jobs, log_dir)

      # --- Phase 3: determine code_related ---

      if triage[:verdict] == :code
        # Pre-triage was confident: skip Claude evaluation
        log "Issue ##{iid}: code failure detected by pre-triage, skipping Claude evaluation (#{triage[:explanation]})"
        explanation = triage[:explanation]
      else
        # Uncertain: fall back to Claude evaluation
        log "Issue ##{iid}: pre-triage uncertain, evaluating with Claude..."
        eval_context = build_eval_context(job_entries)
        eval_result = evaluate_code_related(work_dir, eval_context)

        unless eval_result
          log 'Could not parse pipeline evaluation response, marking as blocked'
          issue.pipeline_failed_infra!
          set_label_blocked(iid)
          notify_localized(iid, :pipeline_eval_failed, mr_url: issue.mr_url)
          return
        end

        explanation = eval_result['explanation'] || 'Aucune explication fournie'

        unless eval_result['code_related']
          issue.pipeline_failed_infra!
          set_label_blocked(iid)
          notify_localized(iid, :pipeline_non_code, mr_url: issue.mr_url, explanation: explanation)
          log "Issue ##{iid}: non-code pipeline failure → blocked (#{explanation})"
          return
        end
      end

      # --- Phase 4: fix ---

      issue._max_fix_rounds = max_fix_rounds
      issue.pipeline_failed_code!

      if issue.blocked?
        set_label_blocked(iid)
        notify_localized(iid, :pipeline_max_rounds, mr_url: issue.mr_url, explanation: explanation)
        log "Issue ##{iid}: code-related pipeline failure but max fix rounds reached → blocked"
        return
      end

      # Enrich job entries with failure category for targeted fix prompts
      categorize_jobs!(job_entries, log_dir)

      log "Issue ##{iid}: code-related pipeline failure, fixing #{job_entries.size} job(s)... (#{explanation})"
      fix_pipeline_failures(work_dir, job_entries, issue)
    rescue RateLimitError => e
      wait = e.wait_seconds
      log_error "Issue ##{iid}: rate limit hit during pipeline fix, parking for #{wait}s"
      begin
        issue.mark_failed!
      rescue AASM::InvalidTransition
        issue.update(status: 'error')
      end
      Issue.where(id: issue.id).update(
        error_message: e.message,
        dc_stdout: @dc_stdout, dc_stderr: @dc_stderr,
        next_retry_at: Sequel.lit("datetime('now', '+#{wait} seconds')")
      )
    rescue StandardError => e
      bt = e.backtrace&.first(10)&.join("\n  ")
      log_error "Pipeline evaluation/fix failed: #{e.class}: #{e.message}"
      log_error "  #{bt}" if bt
      begin
        issue.mark_failed!
      rescue AASM::InvalidTransition
        issue.update(status: 'error')
      end
      issue.update(error_message: "Pipeline fix error: #{e.class}: #{e.message}\n  #{bt}",
                   dc_stdout: @dc_stdout, dc_stderr: @dc_stderr)
      notify_localized(iid, :pipeline_fix_error, error: "#{e.class}: #{e.message[0, 200]}")
    ensure
      FileUtils.rm_rf(work_dir) if work_dir && Dir.exist?(work_dir)
    end
  end

  # ---------------------------------------------------------------------------
  # Pre-triage: classify failures without Claude using GitLab failure_reason
  # and job name/stage heuristics. Returns { verdict:, explanation: }.
  #
  # verdict is :infra, :code, or :uncertain.
  # ---------------------------------------------------------------------------

  INFRA_FAILURE_REASONS = %w[
    runner_system_failure stuck_or_timeout_failure scheduler_failure
    data_integrity_failure job_execution_timeout runner_unsupported
    stale_schedule unmet_prerequisites ci_quota_exceeded
    no_matching_runner trace_size_exceeded archived_failure
  ].freeze

  CODE_FAILURE_REASONS = %w[script_failure].freeze

  DEPLOY_JOB_PATTERN = /\b(deploy|release|publish|rollout|provision|terraform|ansible|helm|k8s|kubernetes|staging|production|review.?app)\b/i.freeze

  def pre_triage(failed_jobs)
    reasons = failed_jobs.map do |job|
      reason = job.respond_to?(:failure_reason) ? job.failure_reason : (job['failure_reason'] if job.is_a?(Hash))
      name   = job.respond_to?(:name) ? job.name : (job['name'] if job.is_a?(Hash))
      stage  = job.respond_to?(:stage) ? job.stage : (job['stage'] if job.is_a?(Hash))
      { reason: reason, name: name.to_s, stage: stage.to_s }
    end

    infra_jobs = reasons.select { |r| INFRA_FAILURE_REASONS.include?(r[:reason]) }
    code_jobs  = reasons.select { |r| CODE_FAILURE_REASONS.include?(r[:reason]) }

    # All jobs have an infra failure_reason → definite infra
    if infra_jobs.size == reasons.size
      names = infra_jobs.map { |r| "#{r[:name]} (#{r[:reason]})" }.join(', ')
      return { verdict: :infra, explanation: "Tous les jobs en echec ont une raison d'infrastructure: #{names}" }
    end

    # All script_failure jobs are deploy/infra by name or stage → infra
    deploy_jobs = reasons.select { |r| r[:name].match?(DEPLOY_JOB_PATTERN) || r[:stage].match?(DEPLOY_JOB_PATTERN) }
    if code_jobs.size == reasons.size && deploy_jobs.size == reasons.size
      names = deploy_jobs.map { |r| r[:name] }.join(', ')
      return { verdict: :infra, explanation: "Tous les jobs en echec sont des jobs de deploiement: #{names}" }
    end

    # Remaining script_failure jobs (at least some non-deploy) → code
    # Deploy jobs will be skipped during fix_pipeline_failures
    if code_jobs.size == reasons.size
      return { verdict: :code, explanation: 'Tous les jobs en echec ont script_failure comme raison' }
    end

    # Mixed or unknown reasons → uncertain
    { verdict: :uncertain, explanation: 'Raisons mixtes ou inconnues' }
  end

  # ---------------------------------------------------------------------------
  # Job categorization: classify each code failure as test/lint/build/unknown
  # by scanning job name, stage, and the first lines of the log.
  # ---------------------------------------------------------------------------

  CATEGORY_PATTERNS = {
    deploy: {
      names: DEPLOY_JOB_PATTERN,
      stages: DEPLOY_JOB_PATTERN,
      logs: /(?!)/ # never match on logs — name/stage is sufficient
    },
    test: {
      names: /\b(r?spec|test|minitest|cucumber|capybara|cypress|jest|mocha)\b/i,
      stages: /\btest/i,
      logs: /\b(failures?|failed examples?|tests?\s+failed|FAILED|assertion|expected\b.*\bgot\b|Error:.*spec)/i
    },
    lint: {
      names: /\b(rubocop|lint|eslint|stylelint|prettier|standardrb|brakeman|bundler.?audit|reek)\b/i,
      stages: /\blint|quality|static/i,
      logs: %r{\b(offenses?\s+detected|violations?|warning:.*\[\w+/\w+\]|rubocop)}i
    },
    build: {
      names: /\b(build|compile|assets|webpack|vite|bundle\s+install|yarn|npm)\b/i,
      stages: /\bbuild|prepare|install/i,
      logs: /\b(syntax error|cannot find|could not|compilation failed|LoadError|ModuleNotFoundError|gem.*not found)\b/i
    }
  }.freeze

  def categorize_jobs!(job_entries, log_dir)
    job_entries.each do |entry|
      entry[:category] = categorize_job(entry, log_dir)
    end
  end

  def categorize_job(entry, log_dir)
    name = entry[:name].to_s
    stage = entry[:stage].to_s

    # Check name and stage first (fast, no I/O)
    CATEGORY_PATTERNS.each do |category, patterns|
      return category if name.match?(patterns[:names]) || stage.match?(patterns[:stages])
    end

    # Check first 200 lines of the log for patterns
    log_path = File.join(log_dir, File.basename(entry[:log_path]))
    if File.exist?(log_path)
      log_head = File.foreach(log_path).first(200)&.join
      if log_head
        CATEGORY_PATTERNS.each do |category, patterns|
          return category if log_head.match?(patterns[:logs])
        end
      end
    end

    :unknown
  end

  # Write full job logs to individual files and return metadata entries.
  # Each entry: { name:, stage:, log_path: (relative to work_dir) }
  def write_job_logs(failed_jobs, log_dir)
    failed_jobs.map do |job|
      name  = job.respond_to?(:name) ? job.name : job['name']
      stage = job.respond_to?(:stage) ? job.stage : job['stage']
      trace = fetch_job_trace(job)

      filename = "#{name.gsub(/[^a-zA-Z0-9_-]/, '_')}.log"
      filepath = File.join(log_dir, filename)
      File.write(filepath, trace)

      rel_path = "tmp/ci_logs/#{filename}"
      { name: name, stage: stage, log_path: rel_path }
    end
  end

  # Build a short summary for the evaluation prompt (no inline logs).
  def build_eval_context(job_entries)
    job_entries.map do |entry|
      "- **#{entry[:name]}** (stage: #{entry[:stage]}) — log complet : `#{entry[:log_path]}`"
    end.join("\n")
  end

  def evaluate_code_related(work_dir, eval_context)
    prompt = <<~PROMPT
      Tu dois analyser un echec de pipeline CI/CD sur une Merge Request et determiner s'il est lie au code ou non.

      ## Jobs en echec

      #{eval_context}

      Lis chaque fichier de log reference ci-dessus pour comprendre la cause de l'echec.

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

    out = danger_claude_prompt(work_dir, prompt, label: '-p (pipeline eval)')
    json_match = out.match(/\{[^{}]*"code_related"\s*:\s*(true|false)[^{}]*\}/m)
    return nil unless json_match

    JSON.parse(json_match[0])
  rescue JSON::ParserError
    nil
  end

  # Fix each failed job in a separate danger-claude call + commit.
  def fix_pipeline_failures(work_dir, job_entries, issue)
    iid       = issue.issue_iid
    branch    = issue.branch_name
    fix_round = issue.fix_round
    extra     = @project_config['extra_prompt']
    skills_line = SkillsInjector.skills_instruction(@all_skills)

    # Fetch full context once for all pipeline fix prompts
    full_context = GitlabHelpers.fetch_full_context(@client, @project_path, iid,
                                                    mr_iid: issue.mr_iid, gitlab_url: @gitlab_url, token: @token, work_dir: work_dir)

    job_entries.each_with_index do |entry, idx|
      category = entry[:category] || :unknown
      if category == :deploy
        log "Skipping deploy job #{idx + 1}/#{job_entries.size}: #{entry[:name]} (not fixable by code change)"
        next
      end
      log "Fixing job #{idx + 1}/#{job_entries.size}: #{entry[:name]} [#{category}] (issue ##{iid})"

      category_instructions = case category
                              when :test
                                <<~CI
                                  Ce job est un job de **tests**. Concentre-toi sur :
                                  - Les tests en echec : lis les messages d'erreur et les stack traces.
                                  - Corrige le code source (pas les tests) sauf si les tests sont manifestement incorrects.
                                  - Si un test echoue a cause d'un changement volontaire de comportement, adapte le test.
                                CI
                              when :lint
                                <<~CI
                                  Ce job est un job de **lint/style**. Concentre-toi sur :
                                  - Les offenses listees dans le log.
                                  - Corrige uniquement les fichiers signales.
                                  - Ne change pas la configuration du linter.
                                CI
                              when :build
                                <<~CI
                                  Ce job est un job de **build/compilation**. Concentre-toi sur :
                                  - Les erreurs de syntaxe, imports manquants, dependances non resolues.
                                  - Corrige le code source pour que la compilation/le build passe.
                                CI
                              else
                                ''
                              end

      with_context_file(work_dir, branch, full_context) do |context_filename|
        prompt = <<~PROMPT
          Tu dois corriger le code pour resoudre l'echec du job CI/CD "#{entry[:name]}" (stage: #{entry[:stage]}).

          Le contexte complet du ticket est dans le fichier `#{context_filename}`. Lis-le si necessaire pour comprendre l'objectif du code.

          ## Log du job

          Le log complet du job est dans le fichier `#{entry[:log_path]}`. Lis-le pour comprendre l'erreur.
          #{"\n## Diagnostic\n\n#{category_instructions}" unless category_instructions.empty?}
          ## Instructions

          #{skills_line}
          - Analyse le log du job en echec.
          - Corrige le code source pour que ce job passe au vert.
          - Respecte les conventions du projet (voir CLAUDE.md si present).
          - Ne modifie que ce qui est necessaire pour corriger l'erreur de ce job.
          - Ne touche pas aux fichiers de configuration CI/CD sauf si c'est la cause directe de l'echec.
          #{"\n## Instructions supplementaires du projet\n\n#{extra}" if extra}
        PROMPT

        danger_claude_prompt(work_dir, prompt, label: "-p (pipeline fix: #{entry[:name]})")
      end
      danger_claude_commit(work_dir, label: "-c (pipeline fix: #{entry[:name]})")
    end

    _out, _err, ok = run_cmd_status(['git', 'log', "origin/#{branch}..HEAD", '--oneline'], chdir: work_dir)
    unless ok
      log 'No new commits after pipeline fix, skipping push'
      issue.update(fix_round: fix_round + 1, pipeline_retrigger_count: 0)
      issue.pipeline_fix_done!
      return
    end

    log "Pushing pipeline fixes to #{branch}..."
    _out, _err, push_ok = run_cmd_status(['git', 'push', 'origin', branch], chdir: work_dir)
    unless push_ok
      log 'Push failed, retrying with --force-with-lease...'
      run_cmd(['git', 'push', '--force-with-lease', 'origin', branch], chdir: work_dir)
    end

    issue.update(fix_round: fix_round + 1, pipeline_retrigger_count: 0,
                 dc_stdout: @dc_stdout, dc_stderr: @dc_stderr)
    issue.pipeline_fix_done! # fixing_pipeline → checking_pipeline
    notify_localized(iid, :pipeline_fix_success, mr_url: issue.mr_url, count: job_entries.size, round: fix_round + 1)
    log "Issue ##{iid}: pipeline fix pushed — #{job_entries.size} job(s) (round #{fix_round + 1})"
  end

  def fetch_failed_jobs(pipeline)
    pid = pipeline_id(pipeline)
    jobs = @client.pipeline_jobs(@project_path, pid, per_page: 100)
    jobs.select do |j|
      status = j.respond_to?(:status) ? j.status : j['status']
      allow_failure = j.respond_to?(:allow_failure) ? j.allow_failure : j['allow_failure']
      status == 'failed' && !allow_failure
    end
  rescue Gitlab::Error::ResponseError => e
    log_error "Failed to fetch pipeline jobs: #{e.message}"
    []
  end

  def fetch_job_trace(job)
    jid = job.respond_to?(:id) ? job.id : job['id']
    @client.job_trace(@project_path, jid).to_s
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
    pipeline.respond_to?(:id) ? pipeline.id : pipeline['id']
  end
end

# frozen_string_literal: true

class IssueProcessor
  include DangerClaudeRunner

  def initialize(client:, config:, project_config:, logger:, token:)
    init_runner(client: client, config: config, project_config: project_config, logger: logger, token: token)
  end

  def process(issue)
    iid   = issue.issue_iid
    title = issue.issue_title

    log "Processing issue ##{iid}: #{title}"
    issue.start_processing! # pending → cloning
    Issue.where(id: issue.id).update(started_at: Sequel.lit("datetime('now')"))

    # Verify issue is still open
    current = @client.issue(@project_path, iid)
    if current.state != "opened"
      log "Issue ##{iid} is no longer open (#{current.state}), skipping"
      issue._issue_closed = true
      issue.clone_complete! # cloning → over
      Issue.where(id: issue.id).update(finished_at: Sequel.lit("datetime('now')"))
      return
    end

    notify_issue(iid, ":robot: **autodev** : traitement en cours...")

    # Check for partial progress from previous attempt
    previous_branch = issue.branch_name
    reuse_branch = previous_branch && branch_exists_on_remote?(previous_branch)
    skip_to_mr = false

    if reuse_branch
      log "Branch #{previous_branch} already exists on remote, checking for recovery..."
      skip_to_mr = true if %w[creating_mr reviewing].include?(issue.status)
    end

    work_dir = "/tmp/autodev_#{@project_path.gsub("/", "_")}_#{iid}"
    begin
      if skip_to_mr
        clone_repo(work_dir)
        fetch_and_checkout(work_dir, previous_branch)
        branch_name = previous_branch
        issue._skip_to_mr = true
        issue.clone_complete! # cloning → creating_mr
      else
        # 1. Clone
        clone_repo(work_dir)

        # 2. Branch — reuse existing remote branch or create a new one
        if reuse_branch
          log "Reusing existing branch: #{previous_branch}"
          fetch_and_checkout(work_dir, previous_branch)
          branch_name = previous_branch
        else
          branch_name = create_branch(work_dir, iid, title)
        end
        issue.update(branch_name: branch_name)
        issue.clone_complete! # cloning → checking_spec

        # 3. Fetch full issue context
        context = GitlabHelpers.fetch_issue_context(@client, @project_path, iid, gitlab_url: @gitlab_url, token: @token, work_dir: work_dir)

        # 4. Check specification clarity
        if check_specification(work_dir, context, iid, issue)
          return # spec_unclear! was fired → needs_clarification
        end
        # spec_clear! was fired → implementing

        # 5. Ensure CLAUDE.md exists
        ensure_claude_md(work_dir)

        # 6. Inject default skills if project lacks its own
        SkillsInjector.inject(work_dir, logger: @logger, project_path: @project_path)

        # 7. Implement
        implement(work_dir, context, iid)
        issue.impl_complete! # implementing → committing

        # 8. Commit
        commit(work_dir)
        issue.commit_complete! # committing → pushing

        # 9. Verify changes + Push
        verify_changes(work_dir, branch_name)
        push(work_dir, branch_name)
        issue.push_complete! # pushing → creating_mr
      end

      # 10. Create MR
      mr = create_merge_request(work_dir, iid, branch_name, title)
      issue.update(mr_iid: mr.iid, mr_url: mr.web_url)
      issue.mr_created! # creating_mr → reviewing

      # 11. Labels
      update_labels(iid)

      # 12. Review (non-fatal)
      run_review(mr.web_url)

      issue.review_complete! # reviewing → checking_pipeline
      Issue.where(id: issue.id).update(
        finished_at: Sequel.lit("datetime('now')"),
        pipeline_retrigger_count: 0,
        dc_stdout: @dc_stdout, dc_stderr: @dc_stderr
      )
      notify_issue(iid, ":white_check_mark: **autodev** : MR creee : #{mr.web_url}")
      log "Issue ##{iid} completed: #{mr.web_url}"

    rescue StandardError => e
      bt = e.backtrace&.first(10)&.join("\n  ")
      retry_count = (issue.retry_count || 0) + 1
      max_retries = (@project_config["max_retries"] || @config["max_retries"] || 3).to_i
      backoff = (@project_config["retry_backoff"] || @config["retry_backoff"] || 30).to_i
      backoff_seconds = backoff * (2**(retry_count - 1))

      begin
        issue.mark_failed!
      rescue AASM::InvalidTransition
        issue.update(status: "error")
      end

      fields = {
        error_message: "#{e.class}: #{e.message}\n  #{bt}",
        dc_stdout: @dc_stdout, dc_stderr: @dc_stderr,
        retry_count: retry_count,
        finished_at: Sequel.lit("datetime('now')")
      }

      if retry_count < max_retries
        fields[:next_retry_at] = Sequel.lit("datetime('now', '+#{backoff_seconds} seconds')")
        log_error "Issue ##{iid} failed (attempt #{retry_count}/#{max_retries}, retry in #{backoff_seconds}s): #{e.class}: #{e.message}"
      else
        log_error "Issue ##{iid} failed (attempt #{retry_count}/#{max_retries}, no more retries): #{e.class}: #{e.message}"
      end

      Issue.where(id: issue.id).update(**fields)
      notify_issue(iid, ":x: **autodev** : echec — #{e.class}: #{e.message[0, 200]}")
      log_error "  #{bt}" if bt
    ensure
      FileUtils.rm_rf(work_dir) if work_dir && Dir.exist?(work_dir)
    end
  end

  private

  def clone_repo(work_dir)
    FileUtils.rm_rf(work_dir) if Dir.exist?(work_dir)

    uri = URI.parse(@gitlab_url)
    host_port = uri.port && ![80, 443].include?(uri.port) ? "#{uri.host}:#{uri.port}" : uri.host
    clone_url = "#{uri.scheme}://oauth2:#{@token}@#{host_port}/#{@project_path}.git"

    clone_depth = @project_config["clone_depth"] || 1
    sparse_paths = @project_config["sparse_checkout"]
    target = @project_config["target_branch"]

    cmd = ["git", "clone"]
    cmd += ["--depth", clone_depth.to_s] if clone_depth.positive?
    cmd += ["--branch", target] if target
    if sparse_paths.is_a?(Array) && sparse_paths.any?
      cmd += ["--filter=blob:none", "--sparse"]
    end
    cmd += [clone_url, work_dir]

    log "Cloning #{@project_path} (depth: #{clone_depth.positive? ? clone_depth : "full"})..."
    run_cmd(cmd)

    if sparse_paths.is_a?(Array) && sparse_paths.any?
      log "Setting up sparse checkout: #{sparse_paths.join(", ")}"
      run_cmd(["git", "sparse-checkout", "set"] + sparse_paths, chdir: work_dir)
    end
  end

  def fetch_and_checkout(work_dir, branch)
    # --depth implies --single-branch, so the refspec is limited to the cloned
    # branch. We must provide an explicit refspec to fetch other branches.
    run_cmd(["git", "fetch", "origin", "+refs/heads/#{branch}:refs/remotes/origin/#{branch}"], chdir: work_dir)
    run_cmd(["git", "checkout", "-b", branch, "origin/#{branch}"], chdir: work_dir)
  end

  def create_branch(work_dir, iid, title)
    slug = I18n.transliterate(title)
                .downcase
                .gsub(/[^a-z0-9\s-]/, "")
                .gsub(/\s+/, "-")
                .gsub(/-+/, "-")
                .gsub(/^-|-$/, "")[0, 50]
    random = SecureRandom.hex(4)
    branch_name = "autodev/#{iid}-#{slug}-#{random}"

    run_cmd(["git", "checkout", "-b", branch_name], chdir: work_dir)
    log "Created branch: #{branch_name}"
    branch_name
  end

  def ensure_claude_md(work_dir)
    claude_md = File.join(work_dir, "CLAUDE.md")
    return if File.exist?(claude_md)

    log "No CLAUDE.md found, generating..."
    danger_claude_prompt(
      work_dir,
      "Analyse ce projet (structure, technologies, conventions, tests) et cree un fichier CLAUDE.md " \
      "a la racine qui documente ces informations pour guider les futurs developpements. " \
      "Sois concis et factuel."
    )
    danger_claude_commit(work_dir)
  end

  def check_specification(work_dir, context, iid, issue)
    log "Checking specification clarity for ##{iid}..."

    prompt = <<~PROMPT
      Analyse le ticket GitLab suivant et determine si la specification est suffisamment precise
      pour etre implementee. Identifie les ambiguites, informations manquantes ou contradictions.

      #{context}

      ## Instructions de reponse

      Reponds UNIQUEMENT avec un objet JSON valide (sans bloc de code markdown), avec cette structure :
      {
        "clear": true/false,
        "issues": ["description du probleme 1", "description du probleme 2"]
      }

      - Si la specification est suffisamment claire pour etre implementee, reponds {"clear": true, "issues": []}
      - Si elle ne l'est pas, liste les problemes specifiques dans "issues"
      - Sois pragmatique : des details mineurs ne doivent pas bloquer l'implementation
      - Concentre-toi sur les ambiguites qui pourraient mener a une implementation incorrecte
    PROMPT

    out = danger_claude_prompt(work_dir, prompt)

    json_match = out.match(/\{[^{}]*"clear"\s*:\s*(true|false)[^{}]*\}/m)
    unless json_match
      log "Could not parse spec check response, proceeding with implementation"
      issue.spec_clear!
      return false
    end

    result = JSON.parse(json_match[0])

    if result["clear"]
      log "Specification is clear, proceeding"
      issue.spec_clear!
      return false
    end

    issues_list = result["issues"] || []
    if issues_list.empty?
      log "Spec check returned unclear but no issues listed, proceeding"
      issue.spec_clear!
      return false
    end

    comment = <<~COMMENT
      :thinking: **autodev** : la specification necessite des precisions avant implementation.

      #{issues_list.map.with_index(1) { |iss, i| "#{i}. #{iss}" }.join("\n")}

      Merci de repondre a ces questions dans les commentaires. L'implementation reprendra automatiquement.
    COMMENT

    notify_issue(iid, comment.strip)
    issue.spec_unclear!
    Issue.where(id: issue.id).update(clarification_requested_at: Sequel.lit("datetime('now')"))
    log "Issue ##{iid} needs clarification, #{issues_list.size} question(s) posted"
    true
  rescue JSON::ParserError
    log "Could not parse spec check JSON response, proceeding with implementation"
    issue.spec_clear!
    false
  end

  def implement(work_dir, context, iid)
    if @project_config["parallel_agents"]
      plan = evaluate_complexity(work_dir, context, iid)
      if plan
        implement_parallel(work_dir, context, iid, plan)
      else
        log "Complexity evaluation returned no plan, falling back"
        implement_fallback(work_dir, context, iid)
      end
    else
      implement_fallback(work_dir, context, iid)
    end
  end

  def implement_fallback(work_dir, context, iid)
    if @project_config["split_implementation"]
      implement_split(work_dir, context, iid)
    else
      implement_single(work_dir, context, iid)
    end
  end

  # Ask Claude to assess complexity and generate a work plan.
  # Returns nil for simple issues (single-agent is fine),
  # or an array of tasks for parallel execution.
  def evaluate_complexity(work_dir, context, iid)
    prompt = <<~PROMPT
      Analyse le ticket GitLab suivant et determine si l'implementation necessite plusieurs agents
      travaillant en parallele, ou si un seul agent suffit.

      #{context}

      ## Instructions de reponse

      Reponds UNIQUEMENT avec un objet JSON valide (sans bloc de code markdown), avec cette structure :
      {
        "parallel": true/false,
        "reason": "explication courte",
        "tasks": [
          {
            "name": "nom-court-de-la-tache",
            "description": "ce que cet agent doit faire",
            "scope": "fichiers ou repertoires concernes (ex: app/models/, app/controllers/users*)"
          }
        ]
      }

      - `parallel: false` si l'issue est simple (1-3 fichiers, un seul domaine). `tasks` doit etre vide.
      - `parallel: true` si l'issue touche plusieurs couches ou domaines independants.
        Chaque tache doit etre autonome et ne PAS toucher les memes fichiers qu'une autre tache.
        Ajoute toujours une tache "tests" dediee aux tests.
      - Maximum 4 taches. Ne cree pas de taches inutiles.
      - Sois pragmatique : en cas de doute, reponds `parallel: false`.
    PROMPT

    log "Evaluating issue complexity for ##{iid}..."
    out = danger_claude_prompt(work_dir, prompt, label: "-p (complexity eval)")

    json_match = out.match(/\{[^{}]*"parallel"\s*:\s*(true|false).*\}/m)
    return nil unless json_match

    result = JSON.parse(json_match[0])

    unless result["parallel"] && result["tasks"].is_a?(Array) && result["tasks"].size > 1
      log "Issue ##{iid} assessed as simple: #{result["reason"]}"
      return nil
    end

    tasks = result["tasks"].map do |t|
      { name: t["name"].to_s, description: t["description"].to_s, scope: t["scope"].to_s }
    end

    log "Issue ##{iid} assessed as complex (#{tasks.size} tasks): #{result["reason"]}"
    tasks
  rescue JSON::ParserError
    log "Could not parse complexity evaluation, falling back to single agent"
    nil
  end

  # Run N agents in parallel, each in its own worktree with a specific task.
  def implement_parallel(work_dir, context, iid, tasks)
    extra = @project_config["extra_prompt"]
    log "Running #{tasks.size} parallel agents for issue ##{iid}..."

    worktrees = []
    threads = []
    errors = []

    tasks.each_with_index do |task, idx|
      wt_path = "#{work_dir}_task_#{idx}"
      run_cmd(["git", "worktree", "add", wt_path, "HEAD"], chdir: work_dir)
      SkillsInjector.inject(wt_path, logger: @logger, project_path: @project_path)

      # Copy injected agents
      agents_src = File.join(work_dir, ".claude", "agents")
      if Dir.exist?(agents_src)
        agents_dst = File.join(wt_path, ".claude", "agents")
        FileUtils.mkdir_p(agents_dst)
        FileUtils.cp_r(Dir.glob(File.join(agents_src, "*")), agents_dst)
      end

      worktrees << { path: wt_path, task: task }

      prompt = <<~PROMPT
        Tu dois implementer UNE PARTIE d'un ticket GitLab. D'autres agents travaillent
        en parallele sur d'autres parties. Ne fais QUE ta tache assignee.

        ## Ticket complet (pour contexte)

        #{context}

        ## Ta tache

        **#{task[:name]}** : #{task[:description]}

        Scope : `#{task[:scope]}`

        ## Instructions

        - N'implemente QUE ta tache. Ne touche PAS aux fichiers hors de ton scope.
        - Respecte les conventions du projet (voir CLAUDE.md si present).
        - Ajoute les tests correspondant a ta tache si elle n'est pas dediee aux tests.
        - Sois autonome : ne presuppose pas que les autres agents ont deja fait leur travail.
        #{extra ? "\n## Instructions supplementaires du projet\n\n#{extra}" : ""}
      PROMPT

      threads << Thread.new do
        log "Agent #{idx + 1}/#{tasks.size}: #{task[:name]} (#{task[:scope]})"
        danger_claude_prompt(wt_path, prompt, label: "-p (parallel: #{task[:name]})")
      rescue StandardError => e
        errors << { task: task[:name], error: e }
      end
    end

    # Wait for all agents
    threads.each(&:join)

    if errors.any?
      error_names = errors.map { |e| e[:task] }.join(", ")
      log_error "#{errors.size} agent(s) failed: #{error_names}"
    end

    # Merge results from all worktrees into work_dir
    worktrees.each do |wt|
      merge_worktree_files(wt[:path], work_dir, wt[:task][:name])
    end

    # If ALL agents failed, raise
    if errors.size == tasks.size
      raise ImplementationError, "All parallel agents failed: #{errors.map { |e| "#{e[:task]}: #{e[:error].message}" }.join("; ")}"
    end
  ensure
    # Clean up all worktrees
    (worktrees || []).each do |wt|
      if Dir.exist?(wt[:path])
        run_cmd_status(["git", "worktree", "remove", "--force", wt[:path]], chdir: work_dir)
        FileUtils.rm_rf(wt[:path])
      end
    end
  end

  # Copy all modified/new files from a worktree back to work_dir.
  def merge_worktree_files(worktree_path, work_dir, task_name)
    changed, _err, ok = run_cmd_status(
      ["git", "diff", "--name-only", "HEAD"],
      chdir: worktree_path
    )
    untracked, _err, ok2 = run_cmd_status(
      ["git", "ls-files", "--others", "--exclude-standard"],
      chdir: worktree_path
    )

    files = []
    files += changed.split("\n").map(&:strip).reject(&:empty?) if ok
    files += untracked.split("\n").map(&:strip).reject(&:empty?) if ok2
    files.uniq!

    if files.empty?
      log "Agent '#{task_name}' produced no changes"
      return
    end

    log "Merging #{files.size} file(s) from agent '#{task_name}'..."
    files.each do |file|
      src = File.join(worktree_path, file)
      dst = File.join(work_dir, file)
      next unless File.exist?(src)

      FileUtils.mkdir_p(File.dirname(dst))
      FileUtils.cp(src, dst)
    end
  end

  def implement_single(work_dir, context, iid)
    extra = @project_config["extra_prompt"]
    prompt = <<~PROMPT
      Tu dois implementer le ticket GitLab suivant. Lis attentivement le contexte complet ci-dessous,
      puis implemente les changements necessaires dans le code.

      #{context}

      ## Instructions

      - Implemente TOUS les changements decrits dans l'issue.
      - Respecte les conventions du projet (voir CLAUDE.md si present).
      - Ajoute ou modifie les tests si necessaire.
      - Ne modifie que ce qui est necessaire pour resoudre l'issue.
      #{extra ? "\n## Instructions supplementaires du projet\n\n#{extra}" : ""}
    PROMPT

    log "Running implementation via danger-claude..."
    danger_claude_prompt(work_dir, prompt)
  end

  def implement_split(work_dir, context, iid)
    extra = @project_config["extra_prompt"]
    implementer = detect_agent(work_dir, "implementer")
    test_writer = detect_agent(work_dir, "test-writer")

    # Create a worktree for the test-writer so both can run in parallel
    test_worktree = "#{work_dir}_tests"
    run_cmd(["git", "worktree", "add", test_worktree, "HEAD"], chdir: work_dir)
    SkillsInjector.inject(test_worktree, logger: @logger, project_path: @project_path)
    # Copy injected agents to worktree (they were injected in work_dir by detect_agent)
    agents_src = File.join(work_dir, ".claude", "agents")
    if Dir.exist?(agents_src)
      agents_dst = File.join(test_worktree, ".claude", "agents")
      FileUtils.mkdir_p(agents_dst)
      FileUtils.cp_r(Dir.glob(File.join(agents_src, "*")), agents_dst)
    end

    code_prompt = <<~PROMPT
      Tu dois implementer le ticket GitLab suivant. Lis attentivement le contexte complet ci-dessous,
      puis implemente les changements necessaires dans le code.

      #{context}

      ## Instructions

      - Implemente TOUS les changements decrits dans l'issue.
      - Respecte les conventions du projet (voir CLAUDE.md si present).
      - N'ecris PAS de tests. Les tests seront ecrits en parallele par un autre agent.
      - Ne modifie que ce qui est necessaire pour resoudre l'issue.
      #{extra ? "\n## Instructions supplementaires du projet\n\n#{extra}" : ""}
    PROMPT

    test_prompt = <<~PROMPT
      Tu dois ecrire les tests pour le ticket GitLab suivant. Un autre agent implemente
      le code en parallele. Ecris les tests en te basant sur la specification de l'issue.

      #{context}

      ## Instructions

      - Ecris les tests en te basant sur la specification de l'issue (pas sur le code, il n'est pas encore disponible).
      - Respecte les conventions de test du projet (voir les tests existants).
      - Ne modifie PAS le code source, uniquement les fichiers de test.
      - Couvre les cas nominaux et les cas limites importants.
      - Si tu dois creer des factories/fixtures, fais-le dans les fichiers de test appropriés.
      #{extra ? "\n## Instructions supplementaires du projet\n\n#{extra}" : ""}
    PROMPT

    # Run both agents in parallel
    log "Running implementer + test-writer in parallel..."
    code_error = nil
    test_error = nil

    code_thread = Thread.new do
      danger_claude_prompt(work_dir, code_prompt, agent: implementer, label: "-p (implement code)")
    rescue StandardError => e
      code_error = e
    end

    test_thread = Thread.new do
      danger_claude_prompt(test_worktree, test_prompt, agent: test_writer, label: "-p (write tests)")
    rescue StandardError => e
      test_error = e
    end

    code_thread.join
    test_thread.join

    # Raise code errors first (tests are useless without code)
    raise code_error if code_error

    # Merge test files from worktree into work_dir
    if test_error
      log_error "Test-writer failed (non-fatal): #{test_error.message}"
    else
      merge_test_files(test_worktree, work_dir)
    end
  ensure
    if test_worktree && Dir.exist?(test_worktree)
      run_cmd_status(["git", "worktree", "remove", "--force", test_worktree], chdir: work_dir)
      FileUtils.rm_rf(test_worktree) # fallback if worktree remove failed
    end
  end

  # Copy files modified in the test worktree back to the main work_dir.
  def merge_test_files(test_worktree, work_dir)
    # Get list of new/modified files in worktree
    changed, _err, ok = run_cmd_status(
      ["git", "diff", "--name-only", "HEAD"],
      chdir: test_worktree
    )
    untracked, _err, ok2 = run_cmd_status(
      ["git", "ls-files", "--others", "--exclude-standard"],
      chdir: test_worktree
    )

    files = []
    files += changed.split("\n").map(&:strip).reject(&:empty?) if ok
    files += untracked.split("\n").map(&:strip).reject(&:empty?) if ok2
    files.uniq!

    if files.empty?
      log "Test-writer produced no changes"
      return
    end

    log "Merging #{files.size} test file(s) from worktree..."
    files.each do |file|
      src = File.join(test_worktree, file)
      dst = File.join(work_dir, file)
      next unless File.exist?(src)

      FileUtils.mkdir_p(File.dirname(dst))
      FileUtils.cp(src, dst)
    end
    log "Merged test files: #{files.join(", ")}"
  end

  IMPLEMENTER_AGENT = <<~AGENT
    ---
    name: implementer
    description: Implement code changes from issue specifications. Use proactively for implementation tasks.
    model: sonnet
    ---

    You are a senior developer implementing code changes from a GitLab issue specification.

    Focus exclusively on production code. Do NOT write or modify tests — a separate agent handles testing.

    When implementing:
    1. Read the issue context and CLAUDE.md carefully.
    2. Identify all files that need changes.
    3. Make minimal, focused changes that satisfy the requirements.
    4. Follow existing code patterns and conventions.
  AGENT

  TEST_WRITER_AGENT = <<~AGENT
    ---
    name: test-writer
    description: Write tests from issue specifications. Use proactively for testing tasks.
    model: sonnet
    ---

    You are a senior developer writing tests from an issue specification.
    Another agent is implementing the code in parallel — you do NOT have access to it.

    Focus exclusively on test files. Do NOT modify production code.

    When writing tests:
    1. Read the issue specification carefully to understand expected behavior.
    2. Check existing tests for patterns, helpers, factories, and conventions.
    3. Write tests that verify the specified behavior: nominal cases and edge cases.
    4. Follow the project's test framework and style exactly.
    5. Use descriptive test names that reflect the specification, not the implementation.
  AGENT

  def detect_agent(work_dir, agent_name)
    # Config override
    config_key = "#{agent_name.gsub("-", "_")}_agent"
    config_agent = @project_config[config_key]
    return config_agent if config_agent

    # Project agent
    agent_path = File.join(work_dir, ".claude", "agents", "#{agent_name}.md")
    if File.exist?(agent_path)
      log "Found agent '#{agent_name}' in project"
      return agent_name
    end

    # Inject default
    template = case agent_name
               when "implementer" then IMPLEMENTER_AGENT
               when "test-writer" then TEST_WRITER_AGENT
               else return nil
               end

    log "Injecting default '#{agent_name}' agent"
    FileUtils.mkdir_p(File.dirname(agent_path))
    File.write(agent_path, template)
    agent_name
  end

  def commit(work_dir)
    log "Committing changes via danger-claude..."
    danger_claude_commit(work_dir)
  end

  def verify_changes(work_dir, branch_name)
    target = @project_config["target_branch"] || default_branch(work_dir)
    out, _err, ok = run_cmd_status(
      ["git", "log", "#{target}..#{branch_name}", "--oneline"],
      chdir: work_dir
    )
    if !ok || out.strip.empty?
      raise ImplementationError, "No changes produced by implementation"
    end
  end

  def default_branch(work_dir)
    out, _err, ok = run_cmd_status(["git", "symbolic-ref", "refs/remotes/origin/HEAD", "--short"], chdir: work_dir)
    if ok && !out.empty?
      out.sub("origin/", "")
    else
      "main"
    end
  end

  def push(work_dir, branch_name)
    log "Pushing #{branch_name}..."
    _out, _err, ok = run_cmd_status(["git", "push", "-u", "origin", branch_name], chdir: work_dir)
    unless ok
      log "Push failed, retrying with --force-with-lease..."
      run_cmd(["git", "push", "--force-with-lease", "-u", "origin", branch_name], chdir: work_dir)
    end
  end

  def update_labels(iid)
    labels_to_remove = @project_config["labels_to_remove"] || []
    label_to_add     = @project_config["label_to_add"]

    begin
      gi = @client.issue(@project_path, iid)
      current_labels = gi.labels || []
      new_labels = current_labels - labels_to_remove
      new_labels << label_to_add if label_to_add && !new_labels.include?(label_to_add)
      @client.edit_issue(@project_path, iid, labels: new_labels.join(","))
      log "Labels updated: removed #{labels_to_remove & current_labels}, added #{label_to_add}"
    rescue Gitlab::Error::ResponseError => e
      log_error "Failed to update labels for ##{iid}: #{e.message}"
    end
  end

  def create_merge_request(work_dir, iid, branch_name, issue_title)
    target = @project_config["target_branch"] || default_branch(work_dir)
    commit_msg = run_cmd(["git", "log", "-1", "--format=%B"], chdir: work_dir)
    commit_subject = run_cmd(["git", "log", "-1", "--format=%s"], chdir: work_dir)
    mr_title = commit_subject
    mr_description = "#{commit_msg}\n\nFixes ##{iid}"

    begin
      existing_mrs = @client.merge_requests(@project_path, source_branch: branch_name, state: "opened")
      if existing_mrs.any?
        mr = existing_mrs.first
        log "MR already exists: !#{mr.iid}"
        return mr
      end
    rescue Gitlab::Error::ResponseError
      # Continue to create
    end

    log "Creating MR: #{mr_title}"
    @client.create_merge_request(
      @project_path, mr_title,
      source_branch: branch_name, target_branch: target, description: mr_description
    )
  end

  def run_review(mr_url)
    unless command_exists?("mr-review")
      log "mr-review not installed, skipping review"
      return
    end

    log "Waiting 15s for GitLab to compute diff_refs..."
    sleep 15
    log "Running mr-review on #{mr_url}..."
    _, err, status = Open3.capture3(CLEAN_ENV, "mr-review", "-H", mr_url)
    if status.success?
      log "Review completed successfully"
    else
      log_error "mr-review failed (non-fatal): #{err[0, 300]}"
    end
  rescue StandardError => e
    log_error "mr-review error (non-fatal): #{e.message}"
  end

  def branch_exists_on_remote?(branch_name)
    @client.branch(@project_path, branch_name)
    true
  rescue Gitlab::Error::ResponseError
    false
  end

  def command_exists?(cmd)
    _, status = Open3.capture2e("which", cmd)
    status.success?
  end
end

# frozen_string_literal: true

# Fixes unresolved MR discussions and failed pipeline jobs.
class MrFixer
  include DangerClaudeRunner

  public :cleanup_labels, :apply_label_todo, :apply_label_mr

  def initialize(client:, config:, project_config:, logger:, token:)
    init_runner(client: client, config: config, project_config: project_config, logger: logger, token: token)
  end

  def fix(issue)
    iid        = issue.issue_iid
    mr_iid     = issue.mr_iid
    branch     = issue.branch_name
    fix_round  = issue.fix_round

    log "Checking MR !#{mr_iid} for unresolved discussions (round #{fix_round + 1})..."

    # Verify the issue still has the trigger label
    trigger_label = @config['trigger_label']
    begin
      gi = @client.issue(@project_path, iid)
      unless gi.labels&.include?(trigger_label)
        log "Issue ##{iid} no longer has '#{trigger_label}' label, skipping"
        return
      end
    rescue Gitlab::Error::ResponseError => e
      log_error "Cannot fetch issue ##{iid}: #{e.message}"
      return
    end

    # Fetch unresolved discussions
    discussions = fetch_unresolved_discussions(mr_iid)
    if discussions.empty?
      log "No unresolved discussions on MR !#{mr_iid}"
      issue.update(pipeline_retrigger_count: 0)
      issue.discussions_fixed! # fixing_discussions → checking_pipeline
      log "Issue ##{iid}: no discussions to fix → checking_pipeline"
      return
    end

    log "Found #{discussions.size} unresolved discussion(s) on MR !#{mr_iid}"

    work_dir = "/tmp/autodev_mrfix_#{@project_path.gsub('/', '_')}_#{iid}"
    begin
      clone_and_checkout(work_dir, branch)
      skills_result = SkillsInjector.inject(work_dir, logger: @logger, project_path: @project_path)
      all_skills = skills_result[:all_skills]
      skills_line = SkillsInjector.skills_instruction(all_skills)
      target_branch = default_branch(work_dir)

      # Fetch full context once (issue + all MR discussions)
      full_context = GitlabHelpers.fetch_full_context(
        @client, @project_path, iid,
        mr_iid: mr_iid, gitlab_url: @gitlab_url, token: @token, work_dir: work_dir
      )

      # Use mr-fixer agent if available in the project
      agent = detect_agent(work_dir, 'mr-fixer')

      discussions.each_with_index do |discussion, idx|
        thread_context = format_discussion(discussion, work_dir: work_dir, target_branch: target_branch)
        log "Fixing discussion #{idx + 1}/#{discussions.size}: #{discussion[:title]}"

        extra = @project_config['extra_prompt']
        with_context_file(work_dir, branch, full_context) do |context_filename|
          prompt = <<~PROMPT
            Tu dois corriger le code en reponse a un commentaire de review sur une Merge Request.

            Le contexte complet (issue + discussions MR) est dans le fichier `#{context_filename}`. Lis-le attentivement.

            ## Commentaire de review a traiter

            #{thread_context}

            ## Instructions

            #{skills_line}
            - Le diff ci-dessus montre les lignes exactes concernees par le commentaire.
            - Corrige le code pour repondre au commentaire.
            - Respecte les conventions du projet (voir CLAUDE.md si present).
            - Ne modifie que ce qui est necessaire pour repondre au commentaire.
            - Ne touche pas aux autres parties du code.
            #{"\n## Instructions supplementaires du projet\n\n#{extra}" if extra}
          PROMPT

          danger_claude_prompt(work_dir, prompt, agent: agent)
        end
        danger_claude_commit(work_dir)
        resolve_discussion(mr_iid, discussion[:id])
      end

      # Verify there are new commits
      _out, _err, ok = run_cmd_status(['git', 'log', "origin/#{branch}..HEAD", '--oneline'], chdir: work_dir)
      unless ok
        log 'No new commits after fixing, skipping push'
        issue.update(fix_round: fix_round + 1, pipeline_retrigger_count: 0)
        issue.discussions_fixed!
        return
      end

      # Push
      log "Pushing fixes to #{branch}..."
      _out, _err, push_ok = run_cmd_status(['git', 'push', 'origin', branch], chdir: work_dir)
      unless push_ok
        log 'Push failed, retrying with --force-with-lease...'
        run_cmd(['git', 'push', '--force-with-lease', 'origin', branch], chdir: work_dir)
      end

      issue.update(fix_round: fix_round + 1, pipeline_retrigger_count: 0,
                   dc_stdout: @dc_stdout, dc_stderr: @dc_stderr)
      issue.discussions_fixed! # fixing_discussions → checking_pipeline
      notify_localized(iid, :mr_fix_success, count: discussions.size, mr_url: issue.mr_url, round: fix_round + 1)
      log "MR !#{mr_iid}: fixed #{discussions.size} discussion(s) (round #{fix_round + 1})"
    rescue RateLimitError => e
      wait = e.wait_seconds
      log_error "MR !#{mr_iid}: rate limit hit, parking for #{wait}s"
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
      begin
        issue.mark_failed!
      rescue AASM::InvalidTransition
        issue.update(status: 'error')
      end
      issue.update(error_message: "MR fix error: #{e.class}: #{e.message}\n  #{bt}",
                   dc_stdout: @dc_stdout, dc_stderr: @dc_stderr)
      notify_localized(iid, :mr_fix_error, error: "#{e.class}: #{e.message[0, 200]}")
      log_error "MR fix failed: #{e.class}: #{e.message}"
      log_error "  #{bt}" if bt
    ensure
      FileUtils.rm_rf(work_dir) if work_dir && Dir.exist?(work_dir)
    end
  end

  DEFAULT_MR_FIXER_AGENT = <<~AGENT
    ---
    name: mr-fixer
    description: Fix MR review comments. Use proactively when fixing code review discussions.
    memory: project
    model: sonnet
    ---

    You are a senior developer fixing code review comments on a Merge Request.

    ## Behavior

    Before starting, check your agent memory for patterns you have seen before on this project.

    When fixing a review comment:
    1. Read the diff hunk and the reviewer's comment carefully.
    2. Understand the intent of the original code (see the issue context).
    3. Make the minimal change that addresses the comment.
    4. Do not refactor surrounding code unless the comment explicitly asks for it.
    5. Do not change tests unless the comment is about tests.

    ## Memory

    After fixing all comments, update your agent memory with:
    - Recurring reviewer patterns (e.g., "reviewer X always requests guard clauses")
    - Common mistakes you fixed (e.g., "missing null check on association")
    - Project conventions you discovered that are not in CLAUDE.md
    - Patterns that led to incorrect fixes so you can avoid them next time

    Write concise notes. Focus on what will help you fix faster next time.
  AGENT

  private

  def fetch_unresolved_discussions(mr_iid)
    discussions = @client.merge_request_discussions(@project_path, mr_iid)
    discussions.select { |d| d.notes&.any? && !resolved?(d) }.map do |d|
      first_note = d.notes.first
      { id: d.id, title: first_note.body.to_s[0, 80], notes: d.notes }
    end
  rescue Gitlab::Error::ResponseError => e
    log_error "Failed to fetch MR discussions: #{e.message}"
    []
  end

  def resolved?(discussion)
    resolvable_notes = discussion.notes.select { |n| n.respond_to?(:resolvable) && n.resolvable }
    return true if resolvable_notes.empty?

    resolvable_notes.all? { |n| n.respond_to?(:resolved) && n.resolved }
  end

  # Returns the agent name, injecting a default if needed.
  # Priority: config override > project agent > injected default.
  def detect_agent(work_dir, default_name)
    # Config override takes precedence
    config_agent = @project_config['mr_fixer_agent']
    return config_agent if config_agent

    # Check if the agent file exists in the cloned repo
    agent_path = File.join(work_dir, '.claude', 'agents', "#{default_name}.md")
    if File.exist?(agent_path)
      log "Found agent '#{default_name}' in project"
      return default_name
    end

    # Inject default agent into the clone
    inject_default_mr_fixer_agent(work_dir, agent_path)
    default_name
  end

  def inject_default_mr_fixer_agent(_work_dir, agent_path)
    log 'Injecting default mr-fixer agent'
    FileUtils.mkdir_p(File.dirname(agent_path))
    File.write(agent_path, DEFAULT_MR_FIXER_AGENT)
  end

  def default_branch(work_dir)
    out, _err, ok = run_cmd_status(['git', 'symbolic-ref', 'refs/remotes/origin/HEAD', '--short'], chdir: work_dir)
    if ok && !out.strip.empty?
      out.strip.sub('origin/', '')
    else
      'main'
    end
  end

  def format_discussion(discussion, work_dir: nil, target_branch: nil)
    lines = []
    diff_shown = false

    discussion[:notes].each do |note|
      author = note.author&.name || 'Unknown'
      lines << "### #{author} (#{note.created_at})"

      if note.respond_to?(:position) && note.position
        pos = note.position
        file_path = pos_field(pos, :new_path)
        old_line = pos_field(pos, :old_line)
        new_line = pos_field(pos, :new_line)

        if file_path
          location = "Fichier: `#{file_path}`"
          location << " (ligne #{new_line})" if new_line
          location << " (ancienne ligne #{old_line})" if old_line && !new_line
          lines << location

          # Include the diff hunk for the first note (avoids repetition in replies)
          if !diff_shown && work_dir && target_branch
            hunk = extract_diff_hunk(work_dir, target_branch, file_path, new_line || old_line)
            if hunk
              lines << ''
              lines << '#### Diff'
              lines << '```diff'
              lines << hunk
              lines << '```'
              diff_shown = true
            end
          end
        end
      end

      lines << ''
      lines << note.body.to_s
      lines << ''
    end
    lines.join("\n")
  end

  # Extract the diff hunk containing the given line for a specific file.
  def extract_diff_hunk(work_dir, target_branch, file_path, target_line)
    diff_output, _err, ok = run_cmd_status(
      ['git', 'diff', "origin/#{target_branch}..HEAD", '--', file_path],
      chdir: work_dir
    )
    return nil unless ok && diff_output && !diff_output.strip.empty?

    return diff_output unless target_line

    # Split into hunks and find the one containing target_line
    hunks = diff_output.split(/(?=^@@)/)
    target_line = target_line.to_i

    hunks.each do |hunk|
      next unless hunk.start_with?('@@')

      # Parse hunk header: @@ -old_start,old_count +new_start,new_count @@
      match = hunk.match(/^@@ .+\+(\d+)(?:,(\d+))? @@/)
      next unless match

      hunk_start = match[1].to_i
      hunk_count = (match[2] || 1).to_i

      return hunk.strip if target_line.between?(hunk_start, hunk_start + hunk_count)
    end

    # Fallback: return the full diff if no matching hunk found
    diff_output
  rescue StandardError
    nil
  end

  def pos_field(pos, field)
    if pos.respond_to?(field)
      pos.send(field)
    elsif pos.is_a?(Hash)
      pos[field.to_s] || pos[field]
    end
  end

  def resolve_discussion(mr_iid, discussion_id)
    @client.resolve_merge_request_discussion(@project_path, mr_iid, discussion_id, resolved: true)
    log "Resolved discussion #{discussion_id}"
  rescue Gitlab::Error::ResponseError => e
    log_error "Failed to resolve discussion #{discussion_id}: #{e.message}"
  end
end

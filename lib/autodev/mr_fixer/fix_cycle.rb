# frozen_string_literal: true

class MrFixer
  # Orchestrates the clone-fix-push cycle and error handling for MR discussion fixes.
  # Expects the including class to provide DangerClaudeRunner methods and DiscussionFormatter.
  module FixCycle
    private

    def execute_fix_cycle(issue, discussions)
      work_dir = "/tmp/autodev_mrfix_#{@project_path.gsub('/', '_')}_#{issue.issue_iid}"
      begin
        run_fix_cycle(issue, discussions, work_dir)
      rescue RateLimitError => e
        handle_rate_limit(issue, e)
      rescue StandardError => e
        handle_fix_error(issue, e)
      ensure
        FileUtils.rm_rf(work_dir) if work_dir && Dir.exist?(work_dir)
      end
    end

    def run_fix_cycle(issue, discussions, work_dir)
      @fix_issue = issue
      branch = issue.branch_name
      clone_and_checkout(work_dir, branch)
      env = prepare_fix_environment(work_dir, issue.issue_iid, issue.mr_iid)

      fix_each_discussion(discussions, work_dir, branch, issue.mr_iid, env)

      return finalize_no_commits(issue) unless new_commits?(work_dir, branch)

      push_fixes(work_dir, branch)
      finalize_success(issue, discussions)
    end

    def prepare_fix_environment(work_dir, iid, mr_iid)
      skills_result = SkillsInjector.inject(work_dir, logger: @logger, project_path: @project_path)
      full_context = GitlabHelpers.fetch_full_context(
        @client, @project_path, iid,
        mr_iid: mr_iid, gitlab_url: @gitlab_url, token: @token, work_dir: work_dir
      )
      { skills_line: SkillsInjector.skills_instruction(skills_result[:all_skills]),
        target_branch: default_branch(work_dir),
        full_context: full_context,
        agent: detect_agent(work_dir, 'mr-fixer') }
    end

    def fix_each_discussion(discussions, work_dir, branch, mr_iid, env)
      discussions.each_with_index do |discussion, idx|
        log "Fixing discussion #{idx + 1}/#{discussions.size}: #{discussion[:title]}"
        log_activity(@fix_issue, :discussion_fixing, title: discussion[:title])
        fix_single_discussion(discussion, work_dir, branch, mr_iid, env)
      end
    end

    def fix_single_discussion(discussion, work_dir, branch, mr_iid, env)
      thread_context = format_discussion(discussion, work_dir: work_dir, target_branch: env[:target_branch])
      extra = @project_config['extra_prompt']
      app_section = AppInstructions.prompt_section(@project_config, port_mappings: @port_mappings || [])

      with_context_file(work_dir, branch, env[:full_context]) do |context_filename|
        prompt = build_fix_prompt(context_filename, thread_context, env[:skills_line], extra, app_section)
        danger_claude_prompt(work_dir, prompt, agent: env[:agent])
      end
      danger_claude_commit(work_dir)
      resolve_discussion(mr_iid, discussion[:id])
    end

    def build_fix_prompt(context_filename, thread_context, skills_line, extra, app_section)
      <<~PROMPT
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
        #{"\n#{app_section}" if app_section}
        #{"\n## Instructions supplementaires du projet\n\n#{extra}" if extra}
      PROMPT
    end

    def new_commits?(work_dir, branch)
      _out, _err, ok = run_cmd_status(['git', 'log', "origin/#{branch}..HEAD", '--oneline'], chdir: work_dir)
      ok
    end

    def finalize_no_commits(issue)
      log 'No new commits after fixing, skipping push'
      issue.update(fix_round: issue.fix_round + 1, pipeline_retrigger_count: 0)
      issue.discussions_fixed!
    end

    def push_fixes(work_dir, branch)
      log "Pushing fixes to #{branch}..."
      _out, _err, push_ok = run_cmd_status(['git', 'push', 'origin', branch], chdir: work_dir)
      return if push_ok

      log 'Push failed, retrying with --force-with-lease...'
      run_cmd(['git', 'push', '--force-with-lease', 'origin', branch], chdir: work_dir)
    end

    def finalize_success(issue, discussions)
      round = issue.fix_round + 1
      issue.update(fix_round: round, pipeline_retrigger_count: 0,
                   dc_stdout: @dc_stdout, dc_stderr: @dc_stderr)
      issue.discussions_fixed!
      notify_localized(issue.issue_iid, :mr_fix_success, count: discussions.size, mr_url: issue.mr_url, round: round)
      log_activity(issue, :discussions_fixed, count: discussions.size, round: round)
      log_activity(issue, :pipeline_watch)
      log "MR !#{issue.mr_iid}: fixed #{discussions.size} discussion(s) (round #{round})"
    end
  end
end

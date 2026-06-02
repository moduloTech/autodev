# frozen_string_literal: true

require_relative 'stagnation_checker'
require_relative 'fix_prompts'

class MrFixer
  # Orchestrates the clone-fix-push cycle and error handling for MR discussion fixes.
  # Expects the including class to provide DangerClaudeRunner methods and DiscussionFormatter.
  module FixCycle # rubocop:disable Metrics/ModuleLength
    include StagnationChecker
    include FixPrompts

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
      rebase_branch_on_target(work_dir, branch)
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
      build_fix_env(skills_result, full_context, work_dir, iid)
    end

    def build_fix_env(skills_result, full_context, work_dir, iid)
      ss_dir = ScreenshotUploader.screenshot_dir(@project_path, iid)
      { skills_line: SkillsInjector.skills_instruction(skills_result[:all_skills]),
        target_branch: default_branch(work_dir), full_context: full_context,
        app_section: AppInstructions.prompt_section(
          @project_config, port_mappings: @port_mappings || [], screenshot_dir: ss_dir
        ),
        agent: detect_agent(work_dir, 'mr-fixer') }
    end

    def fix_each_discussion(discussions, work_dir, branch, mr_iid, env)
      @mr_fix_session_id = nil
      discussions.each_with_index do |discussion, idx|
        log "Fixing discussion #{idx + 1}/#{discussions.size}: #{discussion[:title]}"
        log_activity(@fix_issue, :discussion_fixing, title: discussion[:title])
        fix_single_discussion(discussion, work_dir, branch, mr_iid, env)
      end
    end

    def fix_single_discussion(discussion, work_dir, branch, mr_iid, env)
      thread_context = format_discussion(discussion, work_dir: work_dir, target_branch: env[:target_branch])
      run_fix_prompt(thread_context, work_dir, branch, env)
      danger_claude_commit(work_dir, resume: @mr_fix_session_id)
      resolve_discussion(mr_iid, discussion[:id])
    end

    def run_fix_prompt(thread_context, work_dir, branch, env)
      if @mr_fix_session_id
        danger_claude_prompt(work_dir, build_followup_prompt(thread_context),
                             agent: env[:agent], resume: @mr_fix_session_id)
      else
        run_first_fix(thread_context, work_dir, branch, env)
      end
      @mr_fix_session_id = @last_session_id
    end

    def run_first_fix(thread_context, work_dir, branch, env)
      extra = @project_config['extra_prompt']
      with_context_file(work_dir, branch, env[:full_context]) do |context_filename|
        prompt = build_fix_prompt(context_filename, thread_context, env[:skills_line], extra, env[:app_section])
        danger_claude_prompt(work_dir, prompt, agent: env[:agent])
      end
    end

    def new_commits?(work_dir, branch)
      out, _err, ok = run_cmd_status(['git', 'log', "origin/#{branch}..HEAD", '--oneline'], chdir: work_dir)
      ok && !out.empty?
    end

    def finalize_no_commits(issue)
      log 'No new commits after fixing, skipping push'
      issue.update(fix_round: issue.fix_round + 1, pipeline_retrigger_count: 0)
      issue.discussions_fixed!
    end

    def push_fixes(work_dir, branch)
      push_with_lease_fallback(work_dir, branch)
    end

    def finalize_success(issue, discussions)
      ScreenshotUploader.process(client: @client, project_path: @project_path,
                                 iid: issue.issue_iid, logger: @logger)
      round = issue.fix_round + 1
      issue.update(fix_round: round, pipeline_retrigger_count: 0,
                   dc_stdout: @dc_stdout, dc_stderr: @dc_stderr)
      return if discussion_stagnated?(issue, discussions)

      complete_discussion_fix(issue, discussions, round)
    end

    def complete_discussion_fix(issue, discussions, round)
      issue.discussions_fixed!
      notify_localized(issue.issue_iid, :mr_fix_success, count: discussions.size, mr_url: issue.mr_url, round: round)
      log_activity(issue, :discussions_fixed, count: discussions.size, round: round)
      log_activity(issue, :pipeline_watch)
      log "MR !#{issue.mr_iid}: fixed #{discussions.size} discussion(s) (round #{round})"
    end
  end
end

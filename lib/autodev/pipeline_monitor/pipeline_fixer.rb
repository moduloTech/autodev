# frozen_string_literal: true

require_relative 'fix_prompts'

class PipelineMonitor
  # Fixes each failed pipeline job via danger-claude and pushes the result.
  module PipelineFixer
    include FixPrompts

    private

    def dispatch_fix(issue, work_dir, job_entries, explanation, max_fix_rounds)
      issue._max_fix_rounds = max_fix_rounds
      issue.pipeline_failed_code!
      return mark_max_rounds(issue, explanation) if issue.blocked?

      round = issue.fix_round + 1
      log_activity(issue, :pipeline_fixing, count: job_entries.size, round: round)
      log "Issue ##{issue.issue_iid}: fixing #{job_entries.size} job(s)... (#{explanation})"
      fix_pipeline_failures(work_dir, job_entries, issue)
    end

    def mark_max_rounds(issue, explanation)
      apply_label_blocked(issue.issue_iid)
      notify_localized(issue.issue_iid, :pipeline_max_rounds, mr_url: issue.mr_url, explanation: explanation)
      log_activity(issue, :pipeline_max_rounds)
    end

    def fix_pipeline_failures(work_dir, job_entries, issue)
      context = fetch_fix_context(work_dir, issue)
      fix_each_job(work_dir, job_entries, issue, context)
      push_fixes(work_dir, job_entries, issue)
    end

    def fetch_fix_context(work_dir, issue)
      {
        skills_line: SkillsInjector.skills_instruction(@all_skills),
        extra: @project_config['extra_prompt'],
        app_section: AppInstructions.prompt_section(@project_config, port_mappings: @port_mappings || []),
        full_context: GitlabHelpers.fetch_full_context(
          @client, @project_path, issue.issue_iid,
          mr_iid: issue.mr_iid, gitlab_url: @gitlab_url, token: @token, work_dir: work_dir
        )
      }
    end

    def fix_each_job(work_dir, job_entries, issue, context)
      job_entries.each_with_index do |entry, idx|
        category = entry[:category] || :unknown
        if category == :deploy
          log "Skipping deploy job #{idx + 1}/#{job_entries.size}: #{entry[:name]}"
          next
        end
        log "Fixing job #{idx + 1}/#{job_entries.size}: #{entry[:name]} [#{category}] (issue ##{issue.issue_iid})"
        fix_single_job(work_dir, entry, issue, context)
      end
    end

    def fix_single_job(work_dir, entry, issue, context)
      with_context_file(work_dir, issue.branch_name, context[:full_context]) do |context_filename|
        prompt = build_fix_prompt(entry, context_filename, context)
        danger_claude_prompt(work_dir, prompt, label: "-p (pipeline fix: #{entry[:name]})")
      end
      danger_claude_commit(work_dir, label: "-c (pipeline fix: #{entry[:name]})")
    end

    def push_fixes(work_dir, job_entries, issue)
      branch = issue.branch_name
      _out, _err, has_commits = run_cmd_status(['git', 'log', "origin/#{branch}..HEAD", '--oneline'], chdir: work_dir)

      if has_commits
        push_branch(work_dir, branch)
        complete_fix_round(issue, job_entries, pushed: true)
      else
        log 'No new commits after pipeline fix, skipping push'
        complete_fix_round(issue, job_entries, pushed: false)
      end
    end

    def complete_fix_round(issue, job_entries, pushed:)
      round = issue.fix_round + 1
      updates = { fix_round: round, pipeline_retrigger_count: 0 }
      updates.merge!(dc_stdout: @dc_stdout, dc_stderr: @dc_stderr) if pushed
      issue.update(updates)
      issue.pipeline_fix_done!
      notify_fix_pushed(issue, job_entries, round) if pushed
    end

    def notify_fix_pushed(issue, job_entries, round)
      notify_localized(issue.issue_iid, :pipeline_fix_success,
                       mr_url: issue.mr_url, count: job_entries.size, round: round)
      log_activity(issue, :pipeline_fix_pushed)
      log_activity(issue, :pipeline_watch)
      log "Issue ##{issue.issue_iid}: pipeline fix pushed — #{job_entries.size} job(s) (round #{round})"
    end

    def push_branch(work_dir, branch)
      log "Pushing pipeline fixes to #{branch}..."
      _out, _err, push_ok = run_cmd_status(['git', 'push', 'origin', branch], chdir: work_dir)
      return if push_ok

      log 'Push failed, retrying with --force-with-lease...'
      run_cmd(['git', 'push', '--force-with-lease', 'origin', branch], chdir: work_dir)
    end
  end
end

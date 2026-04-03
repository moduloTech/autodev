# frozen_string_literal: true

require_relative 'error_handler'

class PipelineMonitor
  # Evaluates pipeline failures: pre-triage, clone, Claude evaluation, and fix dispatch.
  module FailureHandler
    include ErrorHandler

    private

    def handle_red(issue, pipeline, max_fix_rounds)
      failed_jobs = fetch_failed_jobs(pipeline)
      return mark_blocked_no_jobs(issue, pipeline) if failed_jobs.empty?

      triage = pre_triage(failed_jobs)
      return if retrigger_if_needed(issue, pipeline, triage)
      return if infra_block?(issue, triage)

      clone_and_fix(issue, failed_jobs, triage, max_fix_rounds)
    rescue RateLimitError => e
      handle_rate_limit(issue, e)
    rescue StandardError => e
      handle_failure_error(issue, e)
    end

    def mark_blocked_no_jobs(issue, pipeline)
      log "No failed jobs for pipeline ##{pipeline_id(pipeline)}, marking as blocked"
      issue.pipeline_failed_infra!
      apply_label_blocked(issue.issue_iid)
      notify_localized(issue.issue_iid, :pipeline_no_failed_jobs, mr_url: issue.mr_url)
    end

    def retrigger_if_needed(issue, pipeline, triage)
      return false if triage[:verdict] == :code
      return false if (issue.pipeline_retrigger_count || 0) >= 1

      log "Pipeline failed (pre-triage: #{triage[:verdict]}), retriggering..."
      @client.retry_pipeline(@project_path, pipeline_id(pipeline))
      issue.update(pipeline_retrigger_count: (issue.pipeline_retrigger_count || 0) + 1)
      true
    rescue Gitlab::Error::ResponseError => e
      log_error "Failed to retrigger pipeline: #{e.message}"
      false
    end

    def infra_block?(issue, triage)
      return false unless triage[:verdict] == :infra

      issue.pipeline_failed_infra!
      apply_label_blocked(issue.issue_iid)
      notify_localized(issue.issue_iid, :pipeline_infra_pretriage,
                       mr_url: issue.mr_url, explanation: triage[:explanation])
      log "Issue ##{issue.issue_iid}: infra failure → blocked (#{triage[:explanation]})"
      true
    end

    def clone_and_fix(issue, failed_jobs, triage, max_fix_rounds)
      work_dir = "/tmp/autodev_pipeline_#{@project_path.gsub('/', '_')}_#{issue.issue_iid}"
      begin
        prepare_work_dir(work_dir, issue)
        job_entries = write_and_categorize_jobs(work_dir, failed_jobs)
        explanation = resolve_explanation(issue, work_dir, triage, job_entries)
        dispatch_fix(issue, work_dir, job_entries, explanation, max_fix_rounds) if explanation
      ensure
        FileUtils.rm_rf(work_dir) if work_dir && Dir.exist?(work_dir)
      end
    end

    def prepare_work_dir(work_dir, issue)
      clone_and_checkout(work_dir, issue.branch_name)
      @all_skills = SkillsInjector.inject(work_dir, logger: @logger, project_path: @project_path)[:all_skills]
    end

    def write_and_categorize_jobs(work_dir, failed_jobs)
      log_dir = File.join(work_dir, 'tmp', 'ci_logs')
      FileUtils.mkdir_p(log_dir)
      entries = write_job_logs(failed_jobs, log_dir)
      categorize_jobs!(entries, log_dir)
      entries
    end

    def resolve_explanation(issue, work_dir, triage, job_entries)
      if triage[:verdict] == :code
        log "Issue ##{issue.issue_iid}: code failure by pre-triage (#{triage[:explanation]})"
        return triage[:explanation]
      end

      evaluate_with_claude(issue, work_dir, job_entries)
    end

    def evaluate_with_claude(issue, work_dir, job_entries)
      log "Issue ##{issue.issue_iid}: pre-triage uncertain, evaluating with Claude..."
      eval_result = evaluate_code_related(work_dir, build_eval_context(job_entries))
      return block_and_log(issue, :pipeline_eval_failed) unless eval_result

      explanation = eval_result['explanation'] || 'Aucune explication fournie'
      return block_and_log(issue, :pipeline_non_code, explanation: explanation) unless eval_result['code_related']

      explanation
    end

    def block_and_log(issue, notification, explanation: nil)
      issue.pipeline_failed_infra!
      apply_label_blocked(issue.issue_iid)
      opts = { mr_url: issue.mr_url }
      opts[:explanation] = explanation if explanation
      notify_localized(issue.issue_iid, notification, **opts)
      nil
    end

    def dispatch_fix(issue, work_dir, job_entries, explanation, max_fix_rounds)
      issue._max_fix_rounds = max_fix_rounds
      issue.pipeline_failed_code!

      if issue.blocked?
        apply_label_blocked(issue.issue_iid)
        notify_localized(issue.issue_iid, :pipeline_max_rounds, mr_url: issue.mr_url, explanation: explanation)
        return
      end

      log "Issue ##{issue.issue_iid}: fixing #{job_entries.size} job(s)... (#{explanation})"
      fix_pipeline_failures(work_dir, job_entries, issue)
    end
  end
end

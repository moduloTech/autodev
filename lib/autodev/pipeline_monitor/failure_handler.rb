# frozen_string_literal: true

require_relative 'error_handler'
require_relative 'stagnation_detector'

class PipelineMonitor
  # Evaluates pipeline failures: pre-triage, clone, Claude evaluation, and fix dispatch.
  module FailureHandler
    include ErrorHandler
    include StagnationDetector

    private

    def handle_red(issue, pipeline)
      clear_pipeline_poll_since(issue)
      failed_jobs = fetch_failed_jobs(pipeline)
      return handle_no_failed_jobs(issue, pipeline) if failed_jobs.empty?

      triage_and_fix(issue, pipeline, failed_jobs)
    rescue RateLimitError => e
      handle_rate_limit(issue, e)
    rescue StandardError => e
      handle_failure_error(issue, e)
    end

    def triage_and_fix(issue, pipeline, failed_jobs)
      log_activity(issue, :pipeline_red, count: failed_jobs.size)
      triage = pre_triage(failed_jobs)
      return if retrigger_if_needed(issue, pipeline, triage)
      return if infra_skip?(issue, triage)

      check_stagnation_and_fix(issue, failed_jobs, triage)
    end

    def handle_no_failed_jobs(_issue, pipeline)
      log "No failed jobs for pipeline ##{pipeline_id(pipeline)}, staying in checking_pipeline"
    end

    def retrigger_if_needed(issue, pipeline, triage)
      return false if triage[:verdict] == :code
      return false if (issue.pipeline_retrigger_count || 0) >= 1

      log "Pipeline failed (pre-triage: #{triage[:verdict]}), retriggering..."
      @client.retry_pipeline(@project_path, pipeline_id(pipeline))
      issue.update(pipeline_retrigger_count: (issue.pipeline_retrigger_count || 0) + 1)
      log_activity(issue, :pipeline_retrigger, verdict: triage[:verdict])
      true
    rescue Gitlab::Error::ResponseError => e
      log_error "Failed to retrigger pipeline: #{e.message}"
      false
    end

    def infra_skip?(issue, triage)
      return false unless triage[:verdict] == :infra

      log "Issue ##{issue.issue_iid}: infra failure, staying in checking_pipeline"
      log_activity(issue, :pipeline_infra)
      true
    end

    # -- Stagnation detection --

    def check_stagnation_and_fix(issue, failed_jobs, triage)
      signature = compute_pipeline_signature(failed_jobs)
      if stagnated?(issue, :pipeline, signature)
        handle_stagnation(issue, :pipeline)
        return
      end

      update_stagnation_signature(issue, :pipeline, signature)
      clone_and_fix(issue, failed_jobs, triage)
    end

    # -- Clone and fix --

    def clone_and_fix(issue, failed_jobs, triage)
      work_dir = "/tmp/autodev_pipeline_#{@project_path.gsub('/', '_')}_#{issue.issue_iid}"
      begin
        prepare_work_dir(work_dir, issue)
        job_entries = write_and_categorize_jobs(work_dir, failed_jobs)
        explanation = resolve_explanation(issue, work_dir, triage, job_entries)
        dispatch_fix(issue, work_dir, job_entries, explanation) if explanation
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
      log_activity(issue, :pipeline_evaluating)
      eval_result = evaluate_code_related(work_dir, build_eval_context(job_entries))
      interpret_eval_result(issue, eval_result)
    end

    def interpret_eval_result(issue, eval_result)
      unless eval_result
        log "Issue ##{issue.issue_iid}: evaluation failed, staying in checking_pipeline"
        return nil
      end

      unless eval_result['code_related']
        log "Issue ##{issue.issue_iid}: non-code failure, staying in checking_pipeline"
        return nil
      end

      eval_result['explanation'] || 'Aucune explication fournie'
    end
  end
end

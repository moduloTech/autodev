# frozen_string_literal: true

require_relative 'error_handler'
require_relative 'stagnation_detector'

class PipelineMonitor
  # Evaluates pipeline failures: pre-triage, clone, Claude evaluation, and fix dispatch.
  module FailureHandler
    include ErrorHandler
    include StagnationDetector

    # Regexes used to dedup recurring failure-state lines in the activity note.
    # An issue stuck in checking_pipeline (per the "no blocked state" design) would
    # otherwise append fresh lines for these events on every poll cycle and blow
    # past GitLab's 1M-char note cap after ~25 days at the default 5min interval.
    PIPELINE_RED_PATTERN = /— :x: Pipeline (en echec|failed)/
    PIPELINE_INFRA_PATTERN = /— :warning: (Echec infrastructure|Infrastructure failure)/
    # The third one, PIPELINE_EVAL_PATTERN, lives in `Evaluator` with the call
    # that uses it (Autodev #62).

    private

    # The job fetch sits outside `attempt_fix`'s rescues on purpose (Autodev #62):
    # an unreadable job list is not a fix failure. It raises `ApiUnavailableError`,
    # which must travel to `check` and end the poll with the row untouched, whereas
    # `handle_failure_error` would mark the ticket `error` and post a comment
    # blaming the fix for a GitLab blip. `failed_jobs.empty?` therefore now means
    # what it says — nothing blocking failed — instead of doubling as "we could not
    # find out".
    def handle_red(issue, pipeline)
      clear_pipeline_poll_since(issue)
      failed_jobs = fetch_failed_jobs(pipeline)
      return handle_no_failed_jobs(issue, pipeline) if failed_jobs.empty?

      attempt_fix(issue, pipeline, failed_jobs)
    end

    # Everything from the triage onwards: this is the part that clones, calls
    # danger-claude and pushes, so a failure here really is a fix failure and the
    # ticket goes to `error` with a diagnostic.
    def attempt_fix(issue, pipeline, failed_jobs)
      triage_and_fix(issue, pipeline, failed_jobs)
    rescue RateLimitError => e
      handle_rate_limit(issue, e)
    rescue StandardError => e
      handle_failure_error(issue, e)
    end

    def triage_and_fix(issue, pipeline, failed_jobs)
      log_activity(issue, :pipeline_red, count: failed_jobs.size, replace_pattern: PIPELINE_RED_PATTERN)
      triage = pre_triage(failed_jobs)
      return if retrigger_if_needed(issue, pipeline, triage)
      return if infra_skip?(issue, triage, failed_jobs)

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

    # An :infra/deploy verdict can't be fixed by the branch's code, so we wait in
    # checking_pipeline for recovery. To avoid polling a never-clearing failure
    # forever, track the signature like the code-fix path and bail via
    # handle_stagnation (surfacing `detail` — the failing job + reason) at threshold.
    def infra_skip?(issue, triage, failed_jobs)
      return false unless triage[:verdict] == :infra

      detail = format_failure_detail(failed_jobs)
      signature = compute_pipeline_signature(failed_jobs)
      return true if bail_on_stagnation?(issue, :pipeline, signature, detail: detail)

      update_stagnation_signature(issue, :pipeline, signature)
      log "Issue ##{issue.issue_iid}: infra failure (#{detail}), staying in checking_pipeline"
      log_activity(issue, :pipeline_infra, detail: detail, replace_pattern: PIPELINE_INFRA_PATTERN)
      true
    end

    # -- Stagnation detection --

    # The fix path always ends in danger-claude (either the Claude evaluation of
    # an uncertain verdict, or the per-job fix itself), so it is gated on the
    # Claude quota (Autodev #46). Returning *before* `update_stagnation_signature`
    # matters: a cycle that never looked at the failure must not count towards
    # stagnation, or an outage would burn the whole budget and give the ticket up.
    # `retrigger_if_needed` and `infra_skip?` ran earlier and are unaffected —
    # neither calls Claude.
    def check_stagnation_and_fix(issue, failed_jobs, triage)
      return defer_fix_for_usage(issue) unless claude_available?

      signature = compute_pipeline_signature(failed_jobs)
      return if bail_on_stagnation?(issue, :pipeline, signature, detail: format_failure_detail(failed_jobs))

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
      rebase_branch_on_target(work_dir, issue.branch_name)
      @all_skills = SkillsInjector.inject(work_dir, logger: @logger, project_path: @project_path)[:all_skills]
    end

    def write_and_categorize_jobs(work_dir, failed_jobs)
      log_dir = File.join(work_dir, 'tmp', 'ci_logs')
      FileUtils.mkdir_p(log_dir)
      # categorize_jobs! mutates + returns the entries (Array#each), so it is the value.
      categorize_jobs!(write_job_logs(failed_jobs, log_dir), log_dir)
    end

    def resolve_explanation(issue, work_dir, triage, job_entries)
      if triage[:verdict] == :code
        log "Issue ##{issue.issue_iid}: code failure by pre-triage (#{triage[:explanation]})"
        return triage[:explanation]
      end

      evaluate_with_claude(issue, work_dir, job_entries)
    end
  end
end

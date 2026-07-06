# frozen_string_literal: true

class PipelineMonitor
  # Automatic, backoff-capped recovery of INFRA-origin pipeline stagnations.
  #
  # A ticket that stagnated on an infra/deploy failure ends `done` +
  # `needs_attention: true` + `attention_reason: 'stagnation_pipeline'`. Once the
  # underlying CI recovers (e.g. a fixed shared runner/deploy job) nothing used
  # to re-attempt it. `PollDispatcher#dispatch_infra_recheck` now enqueues these
  # tickets and `recheck_infra_recovery` re-classifies their CURRENT head
  # pipeline — never a stored verdict — to decide whether to re-enter.
  #
  # Design guarantees (matching the "No blocked state" + stagnation safety net):
  # - Only a *recovered* pipeline (green / no failing pipeline) re-enters. A
  #   pipeline still failing on infra keeps waiting; a pipeline now failing on
  #   *code* is deliberately left untouched (a real failure to fix by hand).
  # - Every non-recovery outcome records one bounded attempt (count++ + backoff
  #   stamp). The dispatch pass filters on `infra_recheck_count < cap`, so the
  #   recheck self-limits at the cap and can never loop — a never-recovering
  #   infra failure stays in `needs_attention` permanently.
  module InfraRecheck
    # Returns true only when CI has recovered and the caller should re-enter the
    # pipeline-check flow via ResumeHandler#reenter_via_pipeline_check. Any other
    # outcome (MR closed, still infra-failing, now code-failing, running,
    # uncertain) returns false after recording a bounded, backed-off attempt.
    def recheck_infra_recovery(issue)
      merge_req = @client.merge_request(@project_path, issue.mr_iid)
      if mr_open?(merge_req) && current_pipeline_verdict(merge_req) == :recovered
        log "Issue ##{issue.issue_iid}: infra failure recovered (CI green) → re-entering pipeline check"
        return true
      end

      record_recheck_attempt(issue)
      false
    rescue Gitlab::Error::ResponseError => e
      log_error "Failed to recheck infra recovery for MR !#{issue.mr_iid}: #{e.message}"
      false
    end

    private

    def mr_open?(merge_req)
      GitlabHelpers.field(merge_req, :state) == 'opened'
    end

    # Re-classify the MR's current head pipeline. `:recovered` when it is green
    # or absent (nothing failing anymore); otherwise the fresh `pre_triage`
    # verdict on the currently-failing jobs (`:infra` / `:code` / `:uncertain`),
    # or `:running` / `:other` for a non-terminal pipeline status.
    def current_pipeline_verdict(merge_req)
      pipeline = GitlabHelpers.field(merge_req, :head_pipeline)
      return :recovered if pipeline.nil?

      status = GitlabHelpers.field(pipeline, :status)
      return :recovered if status == 'success'
      return :running if RUNNING_STATUSES.include?(status)
      return :other unless status == 'failed'

      failed_jobs = fetch_failed_jobs(pipeline)
      return :recovered if failed_jobs.empty?

      pre_triage(failed_jobs)[:verdict]
    end

    # Records one bounded, backed-off attempt so the dispatch pass self-limits
    # at the cap. Never re-enters — the caller returns false after this.
    def record_recheck_attempt(issue)
      attempt = (issue.infra_recheck_count || 0) + 1
      issue.update(infra_recheck_count: attempt,
                   infra_recheck_at: infra_recheck_backoff_seconds.seconds.from_now)
      log "Issue ##{issue.issue_iid}: infra recheck attempt #{attempt}/#{infra_recheck_max}, backing off"
    end

    def infra_recheck_max
      (@project_config['infra_recheck_max'] || @config['infra_recheck_max'] ||
        DEFAULT_INFRA_RECHECK_MAX).to_i
    end

    def infra_recheck_backoff_seconds
      (@project_config['infra_recheck_backoff'] || @config['infra_recheck_backoff'] ||
        DEFAULT_INFRA_RECHECK_BACKOFF).to_i
    end
  end
end

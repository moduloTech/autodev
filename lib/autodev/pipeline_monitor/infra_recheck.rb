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
    # uncertain) returns false after recording a bounded, backed-off attempt —
    # except the two that read nothing at all: a GitLab error (Autodev #62) and an
    # MR in a transient state (Autodev #72) return false having spent nothing.
    def recheck_infra_recovery(issue)
      merge_req = @client.merge_request(@project_path, issue.mr_iid)
      verdict = recheck_verdict(issue, merge_req)
      record_recheck_attempt(issue) if verdict == :spend
      verdict == :reenter
    # The boundary of one recheck. `ApiUnavailableError` joins the MR-fetch error
    # that was already handled here (Autodev #62): a cycle that could not read
    # anything must not re-arm the row, and — like `check_stagnation_and_fix` —
    # must not spend one of the bounded attempts either, or an outage burns the
    # whole budget without ever having looked at a pipeline.
    #
    # A 400 arrives here as an `InvalidRequestError`, i.e. deferred like an outage
    # and re-asked every cycle. Left alone deliberately (neutral review of Autodev
    # #95): the pass is one `merge_request` read, it is already capped at
    # `infra_recheck_max` attempts on the paths that spend one, and no cause of a
    # persistent 400 on that endpoint is known.
    rescue Gitlab::Error::ResponseError, ApiUnavailableError => e
      log_error "Failed to recheck infra recovery for MR !#{issue.mr_iid}: #{e.message}"
      false
    end

    private

    # Three answers, and the third is Autodev #72's: re-arm the row, spend one of
    # the bounded attempts, or spend nothing because nothing was read.
    def recheck_verdict(issue, merge_req)
      state = mr_state(merge_req)
      return transient_mr_verdict(issue, state) if MrState.transient?(state)
      return :spend unless state == 'opened' && current_pipeline_verdict(merge_req) == :recovered

      log "Issue ##{issue.issue_iid}: infra failure recovered (CI green) → re-entering pipeline check"
      :reenter
    end

    def mr_state(merge_req)
      GitlabHelpers.field(merge_req, :state)
    end

    # A transient state is not an answer to "has the CI recovered", so it is not a
    # `false` this pass may charge for either (Autodev #72). The test used to be
    # `mr_open?`, i.e. `== 'opened'`, which read a mid-merge MR as "not open" and
    # spent one of the `infra_recheck_max` attempts — the same mistake as burning
    # the budget on an unreachable endpoint, which the rescue above exists to stop.
    #
    # Not re-arming is still the right answer: the row is `done` +
    # `stagnation_pipeline`, `dispatch_infra_recheck` selects exactly that and
    # re-enqueues it next cycle, by which time GitLab has either merged the MR or
    # put it back to `opened`.
    def transient_mr_verdict(issue, state)
      log "Issue ##{issue.issue_iid}: MR !#{issue.mr_iid} is #{state} (GitLab is processing the merge), " \
          'nothing to recheck, not spending an attempt'
      :wait
    end

    # Re-classify the MR's current head pipeline. `:recovered` when it is green
    # or absent (nothing failing anymore); otherwise the fresh `pre_triage`
    # verdict on the currently-failing jobs (`:infra` / `:code` / `:uncertain`),
    # or `:running` / `:other` for a non-terminal pipeline status.
    #
    # `failed_jobs.empty? → :recovered` is only sound because `fetch_failed_jobs`
    # raises on an unreadable job list (Autodev #62). It used to answer `[]`, so a
    # GitLab outage during a recheck read as "nothing fails anymore" and re-armed a
    # row whose pipeline may well have still been red.
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

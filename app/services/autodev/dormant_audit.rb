# frozen_string_literal: true

module Autodev
  # One bounded second look at every row that has stopped moving
  # (Autodev #47 + #48).
  #
  # #47: a `pending` row whose `next_retry_at` is NULL is invisible to
  # `dispatch_new_issues` (it carries `label_doing`, so it is absent from the
  # `labels_todo` query) and to `dispatch_retries` (which requires the stamp).
  # 14 such rows sat frozen on powerpanne/core, the oldest since April 13th.
  #
  # #48: `dispatch_unassignment` only sweeps active rows, on the assumption that
  # a row always eventually moves. A dormant row never does — so a ticket closed
  # or reassigned while parked in `pending`/`error` was never noticed. That
  # matters most precisely when re-arming exists: the closure has to be seen
  # *before* the row restarts, which here is a `return`, not a pass ordering.
  #
  # This class does NOT reimplement the retry mechanics. It repositions state
  # and lets `dispatch_retries` — which runs immediately after — do the work,
  # labels and activity log included. Replaces `dispatch_error_recheck` (#34),
  # whose `error` population is now one of three arms.
  class DormantAudit
    include ExternalState

    # rubocop:disable Metrics/ParameterLists -- six keyword args, one over the
    # default cap; matches the shape IssueProcessor/MrFixer/PipelineMonitor
    # already use (client/config/project_config/logger/token) plus `path` and
    # `now`, both required by the interface the two test files exercise.
    def initialize(client:, path:, config:, project_config:, logger:, now: Time.current)
      @client = client
      @path = path
      @config = config
      @project_config = project_config
      @logger = logger
      @now = now
    end
    # rubocop:enable Metrics/ParameterLists

    # Rows to audit this cycle: dormant, under cap, past backoff. Materialised
    # before any write, because the routing mutates `dormant_recheck_*` and the
    # status — both of which the queries filter on.
    def candidates
      dormant_rows.select { |issue| under_cap?(issue) && backoff_elapsed?(issue) }
    end

    # Returns the number of candidates audited.
    def run
      flag_exhausted!
      candidates.each { |issue| audit(issue) }.size
    end

    private

    # A row that reached the cap and is *still* dormant is one nothing will look
    # at again — the silent death #34's pass had and #47 complains about. Flagged
    # once, with no GitLab read: past the cap it is not a candidate.
    #
    # Nothing is posted to GitLab. The signal is for the operator (/errors, the
    # /admin/health card), not the requester: a row usually gets here by falling
    # dormant in a loop, and a comment would land on a ticket someone is already
    # handling.
    def flag_exhausted!
      dormant_rows.reject { |issue| under_cap?(issue) }
                  .reject(&:needs_attention)
                  .each { |issue| exhaust!(issue) }
    end

    # `attention_detail` is deliberately left nil here: the field renders
    # verbatim (through `web_errors_attention_detail`, "Job(s) en cause : …")
    # so it must hold only a technical token, e.g. a job name (see
    # `stagnation_detector.rb`), never a full sentence — and there is no
    # failing job to name for this reason anyway. The explanation the
    # operator needs is already in `web_errors_explain_attention_dormant_exhausted`,
    # in the right language; the attempt count is already in the activity log
    # via `activity_dormant_exhausted`.
    def exhaust!(issue)
      ::Issue.where(id: issue.id).update_all(
        needs_attention: true, attention_reason: 'dormant_exhausted'
      )
      ::ActivityLogger.warn_event(issue, :dormant_exhausted, cap: cap)
      @logger.warn("Issue ##{issue.issue_iid}: dormant after #{cap} audits, giving up",
                   project: @path)
    end

    # The three arms, before the bound is applied. Kept separate from
    # `candidates` because Task 6 needs the same three populations *past* the
    # cap. The set is small by construction, so filtering in Ruby is clearer
    # than three more SQL predicates.
    def dormant_rows
      pending_arm.to_a + error_arm.to_a + active_arm.to_a
    end

    def base = ::Issue.where(project_path: @path)

    # The bound that keeps a forgotten ticket from making us call GitLab on
    # every poll forever.
    def under_cap?(issue) = (issue.dormant_recheck_count || 0) < cap

    def backoff_elapsed?(issue) = issue.dormant_recheck_at.nil? || issue.dormant_recheck_at <= @now

    # The age threshold is load-bearing: `find_or_create_issue` creates a row
    # with `next_retry_at` NULL and enqueues `:process` right after, so without
    # it every freshly discovered ticket would be audited in that gap.
    def pending_arm
      base.where(status: 'pending', next_retry_at: nil)
          .without_activity_since(@now - pending_window)
    end

    def error_arm
      base.where(status: 'error')
          .where('retry_count > ?', ::Config.max_retries(@project_config, @config))
    end

    def active_arm
      base.where(status: ::Issue::STALLED_STATES)
          .without_activity_since(@now - active_window)
    end

    # Both windows belong to HealthReport, on purpose: the stuck-issues card and
    # this pass must see the same rows, or the card keeps flagging what nothing
    # recovers — the shape of #47.
    def pending_window = health_report.poll_stale_after

    def active_window = health_report.stuck_active_after

    def health_report = @health_report ||= HealthReport.new(config: @config, now: @now)

    # `error_recheck_*` are the pre-#47 names of these knobs. A production
    # config.yml tuned for #34 expressed a policy, not a column name, so it
    # keeps working.
    def cap
      (@project_config['dormant_audit_max'] || @config['dormant_audit_max'] ||
        @project_config['error_recheck_max'] || @config['error_recheck_max'] ||
        PollDispatcher::DEFAULT_DORMANT_AUDIT_MAX).to_i
    end

    def backoff
      (@project_config['dormant_audit_backoff'] || @config['dormant_audit_backoff'] ||
        @project_config['error_recheck_backoff'] || @config['error_recheck_backoff'] ||
        PollDispatcher::DEFAULT_DORMANT_AUDIT_BACKOFF).to_i
    end

    # The counter is bumped *before* the GitLab read: an unreachable project
    # must burn the cap rather than be retried on every cycle forever. Every
    # candidate costs one bounded attempt whether or not it ends up re-armed.
    def audit(issue)
      attempt = (issue.dormant_recheck_count || 0) + 1
      issue.update(dormant_recheck_count: attempt, dormant_recheck_at: backoff.seconds.from_now)
      route(issue, @client.issue(@path, issue.issue_iid), attempt)
    rescue ::Gitlab::Error::ResponseError => e
      @logger.error("Failed to audit dormant ##{issue.issue_iid}: #{e.message}", project: @path)
    end

    # Closure wins over unassignment (a closed ticket is closed whether or not
    # it is still assigned), and both win over re-arming — a ticket that went
    # away or was handed to a human is not ours to restart. That ordering is the
    # substance of #48 and it is a `return`, not a pass ordering.
    #
    # All three outcomes resolve the row: it leaves the arms either terminally
    # (`closed` / `done`) or with a path forward. There is no "declined" outcome
    # here, unlike #34's pass — see Task 6 for where a row can still die quietly.
    def route(issue, gl_issue, attempt)
      if externally_closed?(gl_issue)
        log_outcome(issue, attempt, 'closed on GitLab')
        close_externally(issue)
      elsif !assigned_to_autodev?(gl_issue)
        log_outcome(issue, attempt, 'unassigned')
        stop_unassigned(issue)
      else
        log_outcome(issue, attempt, 'revived')
        revive(issue)
      end
    end

    def log_outcome(issue, attempt, verb)
      @logger.info("Dormant audit #{attempt}/#{cap} for issue ##{issue.issue_iid}: #{verb}",
                   project: @path)
    end

    # Never reimplements the retry mechanics: it repositions the row and lets
    # `dispatch_retries`, which runs immediately after, take it through the
    # usual `:retry_errored` / `:retry_stuck` path — labels and activity log
    # included.
    def revive(issue)
      return ::Issue.revive_stalled!(::Issue.where(id: issue.id)) if ::Issue::STALLED_STATES.include?(issue.status)

      issue.update(retry_count: 0, next_retry_at: Time.current)
    end
  end
end

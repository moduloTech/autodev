# frozen_string_literal: true

class PipelineMonitor
  # The absolute age bound on a pipeline watch (Autodev #53) — the safety net
  # for every reason a row stops moving that we have not identified yet.
  #
  # Stagnation detection is not that net: `update_stagnation_signature(_, :pipeline, _)`
  # is only ever called from `infra_skip?` and `check_stagnation_and_fix`, both
  # under `when 'failed'`. A pipeline that is never red — `manual`, `canceled`,
  # `skipped`, or a head pipeline stuck at `created` — accumulates no signature,
  # so `bail_on_stagnation?` is unreachable for it and `dispatch_pipelines`
  # re-enqueues the row every cycle, forever. Production issue #15894 polled
  # 29 773 times.
  #
  # This bound is deliberately blind to the pipeline's status. It reads one
  # thing — how long the row has sat in `checking_pipeline` without a
  # transition (`issues.checking_pipeline_since`) — and gives the ticket up past
  # `pipeline_watch_max_days`.
  module WatchBound
    private

    # Called as the last statement of `PipelineMonitor#check`, so "the poll
    # ended without a transition" is a condition rather than an enumeration of
    # the branches that go nowhere — which also means the branches Autodev #51
    # is currently rewriting are covered without naming any of them.
    #
    def abandon_expired_watch(issue)
      return unless issue.status == 'checking_pipeline'

      days = pipeline_watch_max_days
      return unless days.positive?

      since = issue.checking_pipeline_since
      return if since.nil? || since > days.days.ago

      give_up_on_watch(issue, days)
    end

    # Mirrors `handle_stagnation`: the ticket is delivered as far as autodev is
    # concerned, and flagged for a human. Two properties are inherited from that
    # path on purpose — the write bypasses AASM (so no `transition` row, no
    # audit entry) and the ticket stays assigned to the autodev user. Both are
    # pre-existing across three give-up paths and changing them belongs in their
    # own ticket.
    #
    # `attention_reason` is deliberately not `stagnation_pipeline`:
    # `dispatch_infra_recheck` selects exactly that value and would re-arm the
    # row. An expired watch is a give-up, not a deferral.
    #
    # `attention_detail` stays nil — it renders through
    # `web_errors_attention_detail` ("Job(s) en cause : %{detail}"), so it may
    # only carry a technical token, and there is no failing job to name here.
    def give_up_on_watch(issue, days)
      log "Issue ##{issue.issue_iid}: pipeline watch older than #{days} days → done"
      issue.update(status: 'done', finished_at: Time.current, checking_pipeline_since: nil,
                   needs_attention: true, attention_reason: 'pipeline_watch_expired')
      apply_label_done(issue.issue_iid)
      notify_localized(issue.issue_iid, :pipeline_watch_expired, mr_url: issue.mr_url, days: days)
      log_activity(issue, :pipeline_watch_expired, days: days)
    end

    # Same resolution shape as `infra_recheck_max`: per-project override, then
    # global, then the baked default — which lives in `Config::DEFAULTS` and is
    # deliberately not restated here, the drift Autodev #50 had to unpick for
    # `post_completion_timeout`. Zero or negative disables the bound: the escape
    # hatch for a project that genuinely gates deploys by hand for a month.
    #
    # Note that a DB-backed project's `to_project_config` only emits its DB
    # columns, so the per-project branch is reachable today only for a YAML-only
    # project — the same situation `infra_recheck_max` is in. See the spec's
    # "Out of scope".
    def pipeline_watch_max_days
      (@project_config['pipeline_watch_max_days'] || @config['pipeline_watch_max_days'] ||
        ::Config::DEFAULTS['pipeline_watch_max_days']).to_i
    end
  end
end

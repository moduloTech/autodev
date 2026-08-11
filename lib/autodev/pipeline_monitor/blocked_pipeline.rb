# frozen_string_literal: true

class PipelineMonitor
  # Resolves a pipeline whose roll-up status is terminal but inconclusive
  # (`manual`, `skipped`) by looking at its jobs (Autodev #51).
  #
  # GitLab reports `manual` when everything that could run has run and what is
  # left needs a human to press play. On a project whose MR pipelines end with a
  # manual `deploy_review` that is the normal end state of a *green* MR — so
  # treating it as "wait and see" waits forever: nothing will ever change the
  # status, and stagnation detection is fed from handle_red only, so no bound
  # ever fires. Measured on powerpanne/core: one pipeline read 12 729 times in
  # 18 days, four finished tickets delivered by hand weeks later.
  #
  # The verdict is taken on the BLOCKING subset (see JobClassifier#blocking_jobs)
  # and asks "did anything that counts fail?", not "did everything succeed?" —
  # in a manual pipeline a blocking job can legitimately sit `created` or
  # `skipped` downstream of the gate, and demanding `success` from it would
  # reintroduce the same infinite wait one level down. Nothing can be *running*:
  # a running job would make the roll-up `running`.
  module BlockedPipeline
    private

    def dispatch_blocked(issue, pipeline, status)
      jobs = fetch_pipeline_jobs(pipeline)
      # nil = GitLab unreachable. Never read that as "nothing failed": an API
      # error must not be the reason a ticket ships. Retried next cycle.
      return log("Pipeline #{status} for MR !#{issue.mr_iid}: jobs unavailable, rechecking next poll") if jobs.nil?

      failed = failed_blocking_jobs(jobs)
      return blocked_red(issue, pipeline, status, failed) if failed.any?

      blocked_green(issue, status, blocking_jobs(jobs).size)
    end

    def blocked_red(issue, pipeline, status, failed)
      names = failed.map { |job| GitlabHelpers.field(job, :name) }.join(', ')
      log "Pipeline #{status} for MR !#{issue.mr_iid} but blocking job(s) failed (#{names}) → treating as red"
      handle_red(issue, pipeline)
    end

    def blocked_green(issue, status, count)
      log "Pipeline #{status} for MR !#{issue.mr_iid}: #{count} blocking job(s), none failed → treating as green"
      handle_green(issue)
    end
  end
end

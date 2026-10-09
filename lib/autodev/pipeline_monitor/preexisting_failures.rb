# frozen_string_literal: true

require_relative 'failure_signature'
require_relative 'target_red_notice'

class PipelineMonitor
  # A blocking job already red on the target branch, for the same reason, is not
  # the merge request's to fix (Autodev #130).
  #
  # Before this, every code failure went to `PipelineFixer`: one danger-claude
  # call and one commit per job, in the ticket's merge request. A job the target
  # had already broken was either "fixed" there with code outside the ticket, or
  # could not be, came back with the same signature, and the request was given up
  # under `stagnation_pipeline` for a cause that was not its own. Measured on 304
  # production fix rounds: 6 handed the fixer such a job, 3 of them nothing else;
  # powerpanne 16735 was given up on 16/09/2026 while `master` was red on the very
  # same `bundle install` error.
  #
  # "Pre-existing" is decided job by job against the latest finished pipeline of
  # the merge request's own target branch: a job of the same name, failed and
  # blocking there, whose failure `FailureSignature` says accounts for the merge
  # request's. Every unknown keeps the job on the merge request's side — today's
  # behaviour — because leaving unfixed a failure the merge request introduced
  # costs more than fixing one it did not.
  #
  # Reached only from `triage_and_fix`, after the retrigger and the infra wait:
  # the one place a fixer would otherwise be launched.
  module PreexistingFailures
    include TargetRedNotice

    # What the target says about this poll's red jobs: the branch, the pipeline
    # that was compared against, and the names of the jobs it explains.
    TargetVerdict = Struct.new(:target_branch, :pipeline, :jobs)

    private

    # What `check_stagnation_and_fix` used to receive whole: only the jobs the
    # target does not explain. Nothing left means the pipeline is held, or a held
    # one was just retried — no fix, no Claude, no stagnation count.
    def fix_own_failures(issue, pipeline, failed_jobs, triage)
      own_jobs = set_aside_preexisting(issue, pipeline, failed_jobs)
      check_stagnation_and_fix(issue, own_jobs, triage) unless own_jobs.empty?
    end

    # The jobs that are the merge request's own, i.e. the ones to fix. An empty
    # answer means this poll fixes nothing: either every red job is the target's
    # (the pipeline is held), or a held pipeline was just retried.
    def set_aside_preexisting(issue, pipeline, failed_jobs)
      return failed_jobs unless polled_target_branch

      target_pipeline = latest_finished_target_pipeline(polled_target_branch)
      own, verdict = split_preexisting(issue, pipeline, failed_jobs, target_pipeline)
      return retry_held_pipeline(issue, pipeline, target_pipeline, own) if holding?(issue, pipeline) && own.any?
      return failed_jobs unless verdict

      note_preexisting(issue, pipeline, verdict)
      return hold_pipeline(issue, pipeline, verdict, failed_jobs) if own.empty?

      release_hold(issue)
      own
    end

    # A hold re-polled on the same two pipelines — the target's latest finished
    # one and the same red jobs here — has the same answer, and the traces are
    # not read again: two of up to 4 MiB each, every poll interval, for as long as
    # a hold lasts. A retried job is a new job id, a new target pipeline a new id,
    # and either one makes the comparison run again.
    def split_preexisting(issue, pipeline, failed_jobs, target_pipeline)
      return [failed_jobs, nil] unless target_pipeline
      if holding?(issue, pipeline) && issue.target_red_hold_key == hold_key(target_pipeline, failed_jobs)
        return [[], verdict_for(target_pipeline, failed_jobs)]
      end

      red_on_target = fetch_failed_jobs(target_pipeline).to_h { |job| [GitlabHelpers.field(job, :name), job] }
      preexisting, own = failed_jobs.partition do |job|
        explained_by_target?(job, red_on_target[GitlabHelpers.field(job, :name)])
      end
      preexisting.empty? ? [failed_jobs, nil] : [own, verdict_for(target_pipeline, preexisting)]
    end

    def verdict_for(target_pipeline, jobs)
      TargetVerdict.new(target_branch: polled_target_branch, pipeline: target_pipeline,
                        jobs: jobs.map { |job| GitlabHelpers.field(job, :name) })
    end

    def hold_key(target_pipeline, failed_jobs)
      "#{pipeline_id(target_pipeline)}:#{failed_jobs.map { |job| GitlabHelpers.field(job, :id) }.sort.join(',')}"
    end

    # The merge request's own target, as GitLab recorded it on the merge request
    # this poll read — `TargetBranch`'s question 2, never the configuration's. A
    # merge request that names none has nothing to be compared to; the rebase on
    # the fix path is what reports it (`MissingTargetBranchError`).
    def polled_target_branch
      named = GitlabHelpers.field(@polled_mr, :target_branch).to_s.strip if @polled_mr
      named.to_s.empty? ? nil : named
    end

    def explained_by_target?(job, target_job)
      return false unless target_job

      target_signature = failure_signature(target_job)
      return false unless target_signature

      FailureSignature.explains?(target_signature, failure_signature(job))
    end

    def failure_signature(job)
      trace = comparable_trace(job)
      trace && FailureSignature.of(trace)
    end

    def holding?(issue, pipeline)
      issue.target_red_hold_pipeline_id.present? && issue.target_red_hold_pipeline_id == pipeline_id(pipeline)
    end

    # Every red job is the target's: nothing to fix and nothing to count. The row
    # stays in `checking_pipeline`, and `@target_red_hold` tells the age bound that
    # this poll saw the target still red — the column alone outlives the poll that
    # wrote it, so it cannot.
    #
    # `target_red_hold_since` is the hold's own clock (owner's decision of
    # 09/10/2026): stamped by the poll that begins the hold, kept for as long as
    # no poll releases it — a new merge request pipeline the target explains too
    # is the same wait on the same broken target.
    def hold_pipeline(issue, pipeline, verdict, failed_jobs)
      @target_red_hold = verdict
      id = pipeline_id(pipeline)
      hold = { target_red_hold_pipeline_id: id, target_red_hold_key: hold_key(verdict.pipeline, failed_jobs),
               target_red_hold_since: issue.target_red_hold_since || Time.current }
      issue.update(hold) unless hold.all? { |column, value| issue.public_send(column) == value }
      log "Issue ##{issue.issue_iid}: every red job of pipeline ##{id} is already red on " \
          "#{verdict.target_branch}, holding until it recovers"
      []
    end

    def release_hold(issue)
      return unless issue.target_red_hold_pipeline_id || issue.target_red_hold_since

      issue.update(target_red_hold_pipeline_id: nil, target_red_hold_key: nil, target_red_hold_since: nil)
    end

    # The target no longer explains every red job of the held pipeline — it shows
    # another failure, a green job, or evidence that can no longer be compared (a
    # truncated trace, no finished pipeline): retry it
    # (the owner's decision) rather than fix it. The run was made against the
    # target as it was; if it fails again, the target does not explain it any more
    # and the next poll fixes it as before — on a branch the fix path rebases on
    # the target first. A retry GitLab did not take keeps the hold, so the next
    # poll asks again.
    def retry_held_pipeline(issue, pipeline, target_pipeline, own)
      id = pipeline_id(pipeline)
      target_unchanged = held_against?(issue, target_pipeline)
      @client.retry_pipeline(@project_path, id)
      release_hold(issue)
      log_retry(issue, id, target_unchanged ? target_pipeline : nil, own)
      []
    rescue ::Gitlab::Error::ResponseError, ::SystemCallError, ::Timeout::Error, ::SocketError,
           ::OpenSSL::SSL::SSLError, ::EOFError => e
      log_error "Failed to retry held pipeline ##{id}: #{e.class}: #{e.message}"
      []
    end

    # The hold key names the target pipeline the hold was decided on. The same
    # one still the latest means the target did not move, so what stopped
    # matching is the merge request's side: a retried or newly red job.
    def held_against?(issue, target_pipeline)
      target_pipeline.present? && issue.target_red_hold_key.to_s.start_with?("#{pipeline_id(target_pipeline)}:")
    end

    # What was observed, not a guess at why (integration review of the alpha-57
    # lot): a target that moved or can no longer be compared, or an unchanged
    # target whose failure the merge request's red jobs no longer match.
    def log_retry(issue, id, unchanged_target, own)
      log "Issue ##{issue.issue_iid}: #{polled_target_branch} no longer explains pipeline ##{id}, retried"
      unless unchanged_target
        return log_activity(issue, :pipeline_target_recovered, target_branch: polled_target_branch)
      end

      log_activity(issue, :pipeline_held_job_diverged,
                   target_branch: polled_target_branch, target_pipeline: pipeline_id(unchanged_target),
                   jobs: own.map { |job| GitlabHelpers.field(job, :name) }.join(', '))
    end
  end
end

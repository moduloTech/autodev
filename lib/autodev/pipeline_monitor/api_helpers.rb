# frozen_string_literal: true

class PipelineMonitor
  # GitLab API interaction helpers for pipeline monitoring.
  module ApiHelpers
    private

    # The pipeline's full job list. There is no return value for "GitLab did not
    # answer" — the read raises `ApiUnavailableError` and the poll ends at
    # `check`'s boundary rescue with the row untouched (Autodev #62).
    #
    # This used to return nil while `fetch_failed_jobs` returned `[]`, and the
    # comment here had to explain which caller could afford which substitute: nil
    # because `dispatch_blocked` reads an empty job list as green (Autodev #51),
    # `[]` because `handle_red`'s caller "already knows the pipeline is red". The
    # second half was wrong — `handle_red` reads `[]` as `handle_no_failed_jobs`
    # and `InfraRecheck` reads it as `:recovered` — which is the whole of Autodev
    # #62's constat 2. Neither substitute exists now, so no caller has to be told
    # which one it got.
    #
    # per_page: 100 without auto_paginate, matching
    # DeployReview#find_deploy_review_job: no configured project has a >100-job
    # pipeline, and the two call sites should move together if one appears.
    def fetch_pipeline_jobs(pipeline)
      GitlabHelpers.answer(:pipeline_jobs) do
        @client.pipeline_jobs(@project_path, pipeline_id(pipeline), per_page: 100)
      end
    end

    # A filter over the list above rather than a second read of the same
    # endpoint: one place fetches a pipeline's jobs, so there is one place where
    # the failure of that fetch has to be got right.
    def fetch_failed_jobs(pipeline)
      fetch_pipeline_jobs(pipeline).select { |j| failed_not_allowed?(j) }
    end

    def failed_not_allowed?(job)
      status = GitlabHelpers.field(job, :status)
      allow = GitlabHelpers.field(job, :allow_failure)
      status == 'failed' && !allow
    end

    # The one read on this path that is still allowed to answer with a substitute
    # (Autodev #62), and the reasons are specific to it: the substitute names
    # itself in the value ("(trace unavailable: …)"), it is written into a log
    # file for a human or for Claude to read as prose rather than compared
    # against anything, and one unreadable trace must not abandon the fix of the
    # four jobs whose traces did arrive. `test/api_failure_is_not_a_verdict_test.rb`
    # holds that exemption explicitly, next to the rule.
    def fetch_job_trace(job)
      jid = GitlabHelpers.field(job, :id)
      @client.job_trace(@project_path, jid).to_s
    rescue Gitlab::Error::ResponseError => e
      log_error "Failed to fetch job trace: #{e.message}"
      "(trace unavailable: #{e.message})"
    end

    def pipeline_id(pipeline)
      GitlabHelpers.field(pipeline, :id)
    end

    def write_job_logs(failed_jobs, log_dir)
      failed_jobs.map { |job| write_single_job_log(job, log_dir) }
    end

    def write_single_job_log(job, log_dir)
      name  = GitlabHelpers.field(job, :name)
      stage = GitlabHelpers.field(job, :stage)
      trace = fetch_job_trace(job)
      filename = "#{name.gsub(/[^a-zA-Z0-9_-]/, '_')}.log"
      # GitLab returns the trace as ASCII-8BIT (raw bytes); accented chars / € make
      # File.write raise Encoding::UndefinedConversionError. Force-decode as UTF-8
      # and scrub any genuinely invalid bytes so the log is always written.
      clean = trace.dup.force_encoding('UTF-8').scrub
      File.write(File.join(log_dir, filename), clean)
      { name: name, stage: stage, log_path: "tmp/ci_logs/#{filename}" }
    end

    def build_eval_context(job_entries)
      job_entries.map do |entry|
        "- **#{entry[:name]}** (stage: #{entry[:stage]}) — log complet : `#{entry[:log_path]}`"
      end.join("\n")
    end
  end
end

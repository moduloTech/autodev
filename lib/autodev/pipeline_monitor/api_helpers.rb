# frozen_string_literal: true

class PipelineMonitor
  # GitLab API interaction helpers for pipeline monitoring.
  module ApiHelpers
    private

    # The pipeline's full job list, or nil when GitLab could not be reached.
    #
    # nil, not [] — the distinction is the whole safety of the `manual` path
    # (Autodev #51): [] means "this pipeline genuinely has no jobs" and reads as
    # green, so an API error swallowed into [] would deliver a ticket nobody
    # verified. fetch_failed_jobs below can afford `[]` because its caller
    # already knows the pipeline is red.
    #
    # per_page: 100 without auto_paginate, matching fetch_failed_jobs and
    # DeployReview#find_deploy_review_job: no configured project has a
    # >100-job pipeline, and the three call sites should move together if one
    # appears.
    def fetch_pipeline_jobs(pipeline)
      @client.pipeline_jobs(@project_path, pipeline_id(pipeline), per_page: 100)
    rescue Gitlab::Error::ResponseError => e
      log_error "Failed to fetch pipeline jobs: #{e.message}"
      nil
    end

    def fetch_failed_jobs(pipeline)
      pid = pipeline_id(pipeline)
      jobs = @client.pipeline_jobs(@project_path, pid, per_page: 100)
      jobs.select { |j| failed_not_allowed?(j) }
    rescue Gitlab::Error::ResponseError => e
      log_error "Failed to fetch pipeline jobs: #{e.message}"
      []
    end

    def failed_not_allowed?(job)
      status = GitlabHelpers.field(job, :status)
      allow = GitlabHelpers.field(job, :allow_failure)
      status == 'failed' && !allow
    end

    def fetch_job_trace(job)
      jid = GitlabHelpers.field(job, :id)
      @client.job_trace(@project_path, jid).to_s
    rescue Gitlab::Error::ResponseError => e
      log_error "Failed to fetch job trace: #{e.message}"
      "(trace unavailable: #{e.message})"
    end

    def fetch_unresolved_discussions(mr_iid)
      discussions = @client.merge_request_discussions(@project_path, mr_iid, per_page: 100).auto_paginate
      discussions.select { |d| d.notes&.any? && !resolved?(d) }
    rescue Gitlab::Error::ResponseError => e
      log_error "Failed to fetch MR discussions: #{e.message}"
      []
    end

    def resolved?(discussion)
      resolvable = discussion.notes.select { |n| n.respond_to?(:resolvable) && n.resolvable }
      return true if resolvable.empty?

      resolvable.all? { |n| n.respond_to?(:resolved) && n.resolved }
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

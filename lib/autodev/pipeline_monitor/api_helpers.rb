# frozen_string_literal: true

class PipelineMonitor
  # GitLab API interaction helpers for pipeline monitoring.
  module ApiHelpers
    private

    def fetch_failed_jobs(pipeline)
      pid = pipeline_id(pipeline)
      jobs = @client.pipeline_jobs(@project_path, pid, per_page: 100)
      jobs.select { |j| failed_not_allowed?(j) }
    rescue Gitlab::Error::ResponseError => e
      log_error "Failed to fetch pipeline jobs: #{e.message}"
      []
    end

    def failed_not_allowed?(job)
      status = job.respond_to?(:status) ? job.status : job['status']
      allow = job.respond_to?(:allow_failure) ? job.allow_failure : job['allow_failure']
      status == 'failed' && !allow
    end

    def fetch_job_trace(job)
      jid = job.respond_to?(:id) ? job.id : job['id']
      @client.job_trace(@project_path, jid).to_s
    rescue Gitlab::Error::ResponseError => e
      log_error "Failed to fetch job trace: #{e.message}"
      "(trace unavailable: #{e.message})"
    end

    def fetch_unresolved_discussions(mr_iid)
      discussions = @client.merge_request_discussions(@project_path, mr_iid)
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
      pipeline.respond_to?(:id) ? pipeline.id : pipeline['id']
    end

    def write_job_logs(failed_jobs, log_dir)
      failed_jobs.map { |job| write_single_job_log(job, log_dir) }
    end

    def write_single_job_log(job, log_dir)
      name  = job.respond_to?(:name) ? job.name : job['name']
      stage = job.respond_to?(:stage) ? job.stage : job['stage']
      trace = fetch_job_trace(job)
      filename = "#{name.gsub(/[^a-zA-Z0-9_-]/, '_')}.log"
      File.write(File.join(log_dir, filename), trace)
      { name: name, stage: stage, log_path: "tmp/ci_logs/#{filename}" }
    end

    def build_eval_context(job_entries)
      job_entries.map do |entry|
        "- **#{entry[:name]}** (stage: #{entry[:stage]}) — log complet : `#{entry[:log_path]}`"
      end.join("\n")
    end
  end
end

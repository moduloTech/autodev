# frozen_string_literal: true

require 'digest'
require 'json'

class PipelineMonitor
  # Detects pipeline stagnation by tracking failure signatures across fix rounds.
  module StagnationDetector
    private

    def compute_pipeline_signature(failed_jobs)
      names = failed_jobs.map { |j| GitlabHelpers.field(j, :name) }.sort
      Digest::SHA256.hexdigest(names.join(','))
    end

    # Concise, human-readable "what actually failed" string for the failing jobs,
    # e.g. "deploy_review (script_failure)" (comma-joined when several). The job
    # name + GitLab failure_reason are already in `failed_jobs`, so surfacing them
    # costs nothing and turns a generic "infra failure" into an actionable pointer.
    # Appends the job's GitLab URL when the API exposed it so the failing job is
    # one click away instead of buried in the pipeline view. Returns "" when no
    # usable job info is present (never nil, so templates interpolate cleanly).
    def format_failure_detail(failed_jobs)
      Array(failed_jobs).filter_map { |job| format_single_job_detail(job) }.join(', ')
    end

    def format_single_job_detail(job)
      name = GitlabHelpers.field(job, :name).to_s
      return nil if name.empty?

      reason = GitlabHelpers.field(job, :failure_reason).to_s
      url = GitlabHelpers.field(job, :web_url).to_s
      label = reason.empty? ? name : "#{name} (#{reason})"
      url.empty? ? label : "#{label} — #{url}"
    end

    def stagnated?(issue, type, signature)
      data = parse_stagnation(issue)
      entry = data[type.to_s] || {}
      entry['signature'] == signature &&
        (entry['count'] || 0) >= stagnation_threshold
    end

    def stagnation_threshold
      (@project_config['stagnation_threshold'] || @config['stagnation_threshold'] || 5).to_i
    end

    def update_stagnation_signature(issue, type, signature)
      data = parse_stagnation(issue)
      entry = data[type.to_s] || {}
      if entry['signature'] == signature
        entry['count'] = (entry['count'] || 0) + 1
      else
        entry = { 'signature' => signature, 'count' => 1 }
      end
      data[type.to_s] = entry
      issue.update(stagnation_signatures: JSON.generate(data))
    end

    def parse_stagnation(issue)
      JSON.parse(issue.stagnation_signatures || '{}')
    rescue JSON::ParserError
      {}
    end

    # Bail out to "delivered, needs a check" when the same failure signature has
    # recurred past the threshold. Shared by the code-fix and infra-wait paths so
    # both reach the identical end state (done + needs_attention).
    def bail_on_stagnation?(issue, type, signature, detail: nil)
      return false unless stagnated?(issue, type, signature)

      handle_stagnation(issue, type, detail: detail)
      true
    end

    # `detail` carries the concrete failing job(s) + reason (see
    # format_failure_detail). It is persisted on the row and threaded into the
    # `stagnation_pipeline` notification/activity so the operator sees *what* to
    # fix without opening the pipeline. It stays empty on the discussions path
    # (whose templates don't reference %{detail}, so the extra var is ignored).
    #
    # The status write, the `checking_pipeline_since` clear, the label, the
    # reassignment and both user-facing sinks all live in
    # `IssueAbandonment#abandon_issue` since Autodev #60 — this used to write
    # `status: 'done'` itself, which emitted no transition row and skipped the AASM
    # callback that owns the watch clock.
    def handle_stagnation(issue, type, detail: nil)
      log "Issue ##{issue.issue_iid}: #{type} stagnation detected → done"
      abandon_issue(issue, :"stagnation_#{type}", detail: detail)
    end
  end
end

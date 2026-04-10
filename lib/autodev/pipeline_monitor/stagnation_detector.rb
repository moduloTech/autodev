# frozen_string_literal: true

require 'digest'
require 'json'

class PipelineMonitor
  # Detects pipeline stagnation by tracking failure signatures across fix rounds.
  module StagnationDetector
    private

    def compute_pipeline_signature(failed_jobs)
      names = failed_jobs.map { |j| j.respond_to?(:name) ? j.name : j['name'] }.sort
      Digest::SHA256.hexdigest(names.join(','))
    end

    def stagnated?(issue, type, signature)
      data = parse_stagnation(issue)
      entry = data[type.to_s] || {}
      entry['signature'] == signature &&
        (entry['count'] || 0) >= (@config['stagnation_threshold'] || 5)
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

    def handle_stagnation(issue, type)
      log "Issue ##{issue.issue_iid}: #{type} stagnation detected → done"
      issue.update(status: 'done', finished_at: Sequel.lit("datetime('now')"))
      apply_label_mr(issue.issue_iid)
      notify_localized(issue.issue_iid, :"stagnation_#{type}", mr_url: issue.mr_url)
      log_activity(issue, :"stagnation_#{type}")
    end
  end
end

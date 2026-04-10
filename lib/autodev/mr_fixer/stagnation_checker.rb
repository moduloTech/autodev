# frozen_string_literal: true

require 'digest'
require 'json'

class MrFixer
  # Discussion stagnation detection for MR fix cycles.
  module StagnationChecker
    private

    def discussion_stagnated?(issue, discussions)
      signature = Digest::SHA256.hexdigest(discussions.map { |d| d[:id] }.sort.join(','))
      data = JSON.parse(issue.stagnation_signatures || '{}') rescue {} # rubocop:disable Style/RescueModifier
      entry = update_stagnation_entry(data, 'discussions', signature)
      issue.update(stagnation_signatures: JSON.generate(data))
      return false unless entry['count'] >= (@config['stagnation_threshold'] || 5)

      transition_to_done_stagnation!(issue)
      true
    end

    def update_stagnation_entry(data, key, signature)
      entry = data[key] || {}
      if entry['signature'] == signature
        entry['count'] = (entry['count'] || 0) + 1
      else
        entry = { 'signature' => signature, 'count' => 1 }
      end
      data[key] = entry
      entry
    end

    def transition_to_done_stagnation!(issue)
      log "Issue ##{issue.issue_iid}: discussion stagnation detected → done"
      issue.update(status: 'done', finished_at: Sequel.lit("datetime('now')"))
      apply_label_mr(issue.issue_iid)
      notify_localized(issue.issue_iid, :stagnation_discussions, mr_url: issue.mr_url)
      log_activity(issue, :stagnation_discussions)
    end
  end
end

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
      return false unless entry['count'] >= stagnation_threshold

      transition_to_done_stagnation!(issue)
      true
    end

    def stagnation_threshold
      (@project_config['stagnation_threshold'] || @config['stagnation_threshold'] || 5).to_i
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

    # The discussions twin of `PipelineMonitor`'s pipeline stagnation, and the
    # fourth give-up path routed through `IssueAbandonment#abandon_issue` by
    # Autodev #60: it used to write `status: 'done'` from `fixing_discussions`
    # itself, so it emitted no transition row and left the ticket on autodev.
    def transition_to_done_stagnation!(issue)
      log "Issue ##{issue.issue_iid}: discussion stagnation detected → done"
      abandon_issue(issue, :stagnation_discussions)
    end
  end
end

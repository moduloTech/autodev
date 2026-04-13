# frozen_string_literal: true

class PipelineMonitor
  # Runs mr-review on the MR after a green pipeline.
  # Manages review_count and transitions via review_done!.
  module Reviewer
    MAX_REVIEW_ROUNDS = 3

    private

    def launch_review(issue)
      log "Launching mr-review for MR !#{issue.mr_iid} (review_count: #{issue.review_count})"
      log_activity(issue, :reviewing)
      success = execute_mr_review(issue)
      increment_review_count(issue) if success
      issue.review_done!
      log_activity(issue, :review_done)
    end

    def execute_mr_review(issue)
      unless command_exists?('mr-review')
        log 'mr-review not installed, skipping review'
        return false
      end

      log 'Waiting 15s for GitLab to compute diff_refs...'
      sleep 15
      run_mr_review_command(issue.mr_url)
    rescue StandardError => e
      log_error "mr-review error (non-fatal): #{e.message}"
      false
    end

    def run_mr_review_command(mr_url)
      log "Running mr-review on #{mr_url}..."
      _, err, status = Open3.capture3(DangerClaudeRunner::CLEAN_ENV, 'mr-review', '-H', mr_url)
      return log('Review completed successfully') || true if status.success?

      log_error "mr-review failed (non-fatal): #{err[0, 300]}"
      false
    end

    def increment_review_count(issue)
      new_count = (issue.review_count || 0) + 1
      Issue.where(id: issue.id).update(review_count: new_count)
      issue.review_count = new_count
      log "Review count incremented to #{new_count} for issue ##{issue.issue_iid}"
    end

    def command_exists?(cmd)
      _, status = Open3.capture2e('which', cmd)
      status.success?
    end
  end
end

# frozen_string_literal: true

class PipelineMonitor
  # Runs mr-review on the MR after a green pipeline.
  # Manages review_count and transitions via review_done!.
  module Reviewer
    MAX_REVIEW_ROUNDS = 3
    # Consecutive mr-review failures before we give up reviewing the MR. Each
    # failed mr-review still fires a state transition, so without a cap the
    # checking_pipeline ↔ reviewing loop runs forever on a persistently
    # broken mr-review (token expired, binary crash, etc.).
    REVIEW_FAILURE_THRESHOLD = 5

    private

    def launch_review(issue)
      log "Launching mr-review for MR !#{issue.mr_iid} (review_count: #{issue.review_count})"
      log_activity(issue, :reviewing)
      if execute_mr_review(issue)
        finalize_review_success(issue)
      else
        finalize_review_failure(issue)
      end
    end

    def finalize_review_success(issue)
      increment_review_count(issue)
      reset_review_failure_count(issue)
      DiscussionSnapshot.capture(context: :post_mr_review, client: @client,
                                 project_path: @project_path, mr_iid: issue.mr_iid,
                                 logger: @logger, issue: issue)
      issue.review_done!
      log_activity(issue, :review_done)
    end

    def finalize_review_failure(issue)
      new_failures = (issue.review_failure_count || 0) + 1
      Issue.where(id: issue.id).update(review_failure_count: new_failures)
      issue.review_failure_count = new_failures
      log "mr-review failed (consecutive failures: #{new_failures}/#{REVIEW_FAILURE_THRESHOLD})"
      return give_up_reviewing(issue) if new_failures >= REVIEW_FAILURE_THRESHOLD

      issue.review_done!
      log_activity(issue, :review_failed, count: new_failures)
    end

    def give_up_reviewing(issue)
      issue.review_giveup!
      apply_label_done(issue.issue_iid)
      reassign_to_author(issue)
      Issue.where(id: issue.id).update_all(finished_at: Time.current, needs_attention: true,
                                           attention_reason: 'review_failures_exhausted')
      notify_localized(issue.issue_iid, :review_failures_exhausted,
                       mr_url: issue.mr_url, count: REVIEW_FAILURE_THRESHOLD)
      log_activity(issue, :review_failures_exhausted, count: REVIEW_FAILURE_THRESHOLD)
      log "Issue ##{issue.issue_iid}: #{REVIEW_FAILURE_THRESHOLD} consecutive mr-review failures → done"
    end

    def reset_review_failure_count(issue)
      return if (issue.review_failure_count || 0).zero?

      Issue.where(id: issue.id).update(review_failure_count: 0)
      issue.review_failure_count = 0
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
      # mr-review is an Open3 call with no timeout and no danger-claude heartbeat of
      # its own (Autodev #50 follow-up): mark liveness right before the unbounded
      # call, as late as possible, so silence in `reviewing` is bounded at one run.
      dc_heartbeat!('mr-review')
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

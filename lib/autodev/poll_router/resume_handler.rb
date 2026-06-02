# frozen_string_literal: true

class PollRouter
  # Handles reentry transitions (done → pending OR done → checking_pipeline)
  # when label_todo is detected on a done issue.
  #
  # Two paths:
  # - If the existing MR is still open, route to `checking_pipeline` so the
  #   next pipeline check sends to `fixing_discussions` (MrFixer addresses
  #   unresolved threads instead of triggering a full re-implementation).
  # - Otherwise, route to `pending` for a full implementation cycle.
  module ResumeHandler
    private

    def handle_reenter(gl_issue, existing)
      @logger.info("Issue ##{gl_issue.iid}: labels_todo detected on done issue, re-entering",
                   project: @project_path)
      return if @config['dry_run']

      if reenter_to_fix?(existing)
        reenter_via_pipeline_check(existing)
      else
        reenter_via_reimplementation(gl_issue, existing)
      end
    end

    # MR must exist and be open. A closed or merged MR means the previous work
    # was discarded or already shipped — a fresh implementation cycle is the right thing.
    def reenter_to_fix?(existing)
      return false unless existing.mr_iid

      mr = @route_client.merge_request(@project_path, existing.mr_iid)
      mr.state == 'opened'
    rescue Gitlab::Error::ResponseError => e
      log_error "Failed to check MR !#{existing.mr_iid} state for reentry: #{e.message}"
      false
    end

    # Preserve mr_iid; reset only what would block the pipeline-fix flow.
    # review_count is forced to 1 so green_post_review (not green_first_review)
    # runs on the next pipeline tick — and to dodge the max_review_rounds
    # short-circuit if the issue had reached the review cap before.
    def reenter_via_pipeline_check(existing)
      existing.reenter_to_check_pipeline!
      existing.update(review_count: 1, stagnation_signatures: nil, fix_round: 0,
                      pipeline_retrigger_count: 0, error_message: nil,
                      finished_at: nil, activity_note_id: nil)
      apply_label_doing(existing.issue_iid)
      log_activity(existing, :reenter_to_fix)
      log "Issue ##{existing.issue_iid}: MR open → checking_pipeline (will route to fixing_discussions)"
    end

    def reenter_via_reimplementation(gl_issue, existing)
      existing.reenter!
      existing.update(review_count: 0, stagnation_signatures: nil, fix_round: 0,
                      error_message: nil, finished_at: nil, started_at: nil,
                      pipeline_retrigger_count: 0, activity_note_id: nil)
      log_activity(existing, :reenter)
      enqueue_issue_processing(gl_issue, existing)
    end
  end
end

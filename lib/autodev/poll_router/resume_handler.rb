# frozen_string_literal: true

class PollRouter
  # Handles reentry transitions (done → pending) when label_todo is detected.
  module ResumeHandler
    private

    def handle_reenter(gl_issue, existing)
      @logger.info("Issue ##{gl_issue.iid}: labels_todo detected on done issue, re-entering",
                   project: @project_path)
      return if @config['dry_run']

      existing.reenter!
      existing.update(review_count: 0, stagnation_signatures: nil, fix_round: 0,
                      error_message: nil, finished_at: nil, started_at: nil,
                      pipeline_retrigger_count: 0)
      log_activity(existing, :reenter)
      enqueue_issue_processing(gl_issue, existing)
    end
  end
end

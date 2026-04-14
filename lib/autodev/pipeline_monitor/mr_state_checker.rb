# frozen_string_literal: true

class PipelineMonitor
  # Detects MRs that are no longer open (merged or closed) and transitions to done.
  module MrStateChecker
    private

    def handle_mr_closed(issue, merge_request)
      state = merge_request.state
      log "MR !#{issue.mr_iid} is no longer open (#{state}), skipping pipeline check"
      apply_label_done(issue.issue_iid)
      Issue.where(id: issue.id).update(finished_at: Sequel.lit("datetime('now')"))
      issue.mr_closed!
      log_activity(issue, :mr_closed, mr_state: state)
      log "Issue ##{issue.issue_iid}: MR #{state} → done"
    end
  end
end

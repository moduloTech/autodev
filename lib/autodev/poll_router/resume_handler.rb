# frozen_string_literal: true

class PollRouter
  # Handles reentry transitions (done → pending OR done → checking_pipeline)
  # when label_todo is detected on a done issue.
  #
  # Three paths:
  # - MR open → route to `checking_pipeline` so the next pipeline check sends
  #   to `fixing_discussions` (MrFixer addresses unresolved threads instead of
  #   triggering a full re-implementation).
  # - MR already merged → skip: the work is shipped, no point re-implementing.
  #   Clear the todo label and stay in `done`.
  # - Anything else (closed without merge, no MR, lookup error) → route to
  #   `pending` for a full implementation cycle.
  module ResumeHandler
    private

    def handle_reenter(gl_issue, existing)
      @logger.info("Issue ##{gl_issue.iid}: labels_todo detected on done issue, re-entering",
                   project: @project_path)
      return if @config['dry_run']

      case reenter_destination(existing)
      when :pipeline_check then reenter_via_pipeline_check(existing)
      when :skip_merged    then skip_reentry_already_merged(existing)
      else                      reenter_via_reimplementation(gl_issue, existing)
      end
    end

    # Inspect the existing MR state to decide the reentry path. A merged MR
    # short-circuits to `:skip_merged` so we don't re-clone, re-implement, and
    # re-push a branch whose content is already in target.
    def reenter_destination(existing)
      return :reimplementation unless existing.mr_iid

      mr = @route_client.merge_request(@project_path, existing.mr_iid)
      case mr.state
      when 'opened' then open_mr_destination(existing)
      when 'merged' then :skip_merged
      else               :reimplementation
      end
    rescue Gitlab::Error::ResponseError => e
      log_error "Failed to check MR !#{existing.mr_iid} state for reentry: #{e.message}"
      :reimplementation
    end

    # An open MR normally means "the human wants the review threads addressed" →
    # `:pipeline_check` (routes to MrFixer). But if the human left recette-KO
    # feedback as a NEW comment on the ISSUE after the last delivery (bug #32),
    # that feedback lives on the issue, not on the MR — the MR-discussion path
    # never reads it and re-delivers the identical MR. Route those to a full
    # `:reimplementation`, the only path that injects issue comments (via
    # GitlabHelpers.fetch_full_context) and that reuses the existing branch/MR.
    def open_mr_destination(existing)
      if GitlabHelpers.human_comment_since?(@route_client, @project_path, existing.issue_iid, existing.finished_at)
        :reimplementation
      else
        :pipeline_check
      end
    end

    # Preserve mr_iid; reset only what would block the pipeline-fix flow.
    # review_count is forced to 1 so green_post_review (not green_first_review)
    # runs on the next pipeline tick — and to dodge the max_review_rounds
    # short-circuit if the issue had reached the review cap before.
    def reenter_via_pipeline_check(existing)
      existing.reenter_to_check_pipeline!
      existing.update(review_count: 1, review_failure_count: 0, stagnation_signatures: nil,
                      fix_round: 0, pipeline_retrigger_count: 0, error_message: nil,
                      finished_at: nil, activity_note_id: nil,
                      needs_attention: false, attention_reason: nil, attention_detail: nil,
                      infra_recheck_count: 0, infra_recheck_at: nil)
      apply_label_doing(existing.issue_iid)
      log_activity(existing, :reenter_to_fix)
      log "Issue ##{existing.issue_iid}: MR open → checking_pipeline (will route to fixing_discussions)"
    end

    def reenter_via_reimplementation(gl_issue, existing)
      existing.reenter!
      existing.update(review_count: 0, review_failure_count: 0, stagnation_signatures: nil,
                      fix_round: 0, error_message: nil, finished_at: nil, started_at: nil,
                      pipeline_retrigger_count: 0, activity_note_id: nil,
                      needs_attention: false, attention_reason: nil, attention_detail: nil)
      log_activity(existing, :reenter)
      enqueue_issue_processing(gl_issue, existing)
    end

    # MR is already merged — the issue's work is shipped. Strip the todo label
    # (so we don't loop on the next poll) and stay in `done` without any
    # AASM transition or processor enqueue.
    def skip_reentry_already_merged(existing)
      apply_label_done(existing.issue_iid)
      log_activity(existing, :reenter_skipped_merged)
      log "Issue ##{existing.issue_iid}: MR !#{existing.mr_iid} already merged → skipping reentry"
    end
  end
end

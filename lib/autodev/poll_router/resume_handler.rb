# frozen_string_literal: true

class PollRouter
  # Handles reentry transitions (done → pending OR done → checking_pipeline)
  # when label_todo is detected on a done issue.
  #
  # Four paths:
  # - MR open → route to `checking_pipeline` so the next pipeline check sends
  #   to `fixing_discussions` (MrFixer addresses unresolved threads instead of
  #   triggering a full re-implementation).
  # - MR already merged → skip: the work is shipped, no point re-implementing.
  #   Clear the todo label and stay in `done`.
  # - MR in a transient state (`MrState::TRANSIENT_STATES` — `locked`) → wait:
  #   conclude nothing and re-read next cycle (Autodev #67, one definition #72).
  # - Anything else (closed without merge, no MR, a state GitLab adds later) →
  #   route to `pending` for a full implementation cycle.
  #
  # What is *not* a path any more is "the lookup failed" (Autodev #67). It used to
  # fall in with the last one, and `:reimplementation` is the most expensive
  # branch there is — full clone, danger-claude, push, on a ticket whose MR may
  # already be merged. Same shape as the four readers Autodev #62 unpicked, and
  # invisible for the same reason: the substitute is a plausible destination. The
  # read now raises and `PollRouter#route` skips this issue for the cycle.
  module ResumeHandler
    private

    def handle_reenter(gl_issue, existing)
      @logger.info("Issue ##{gl_issue.iid}: labels_todo detected on done issue, re-entering",
                   project: @project_path)
      return if @config['dry_run']

      case reenter_destination(existing)
      when :pipeline_check then reenter_via_pipeline_check(existing)
      when :skip_merged    then skip_reentry_already_merged(existing)
      when :wait           then defer_reentry(existing)
      else                      reenter_via_reimplementation(gl_issue, existing)
      end
    end

    # Inspect the existing MR state to decide the reentry path. A merged MR
    # short-circuits to `:skip_merged` so we don't re-clone, re-implement, and
    # re-push a branch whose content is already in target.
    #
    # A transient state is separated from the `else` on purpose: `locked` is
    # GitLab's state while a merge is in flight, so the MR is very likely `merged`
    # a second later, and the `else` branch would clone and re-implement over work
    # that is about to land. It is a wait, not a verdict — the same distinction the
    # poll makes between "the pipeline is still running" and "the pipeline failed".
    # `:reimplementation` stays the answer for a state that really is unknown.
    #
    # Which states are transient is `MrState`'s to say (Autodev #72). This used to
    # be `when 'locked' then :wait`, written by hand one ticket after Autodev #69
    # had put that list in one place so widening the door would be a decision:
    # a second copy, free to diverge, and adding a state to the list would not have
    # reached the reentry path. What stays this reader's own is the destination.
    def reenter_destination(existing)
      return :reimplementation unless existing.mr_iid

      mr = GitlabHelpers.answer(:merge_request) do
        @route_client.merge_request(@project_path, existing.mr_iid)
      end
      return :wait if MrState.transient?(mr.state)

      case mr.state
      when 'opened' then open_mr_destination(existing)
      when 'merged' then :skip_merged
      else               :reimplementation
      end
    end

    # Nothing at all: no transition, no label change, no comment. The todo label
    # stays where the human put it, so `dispatch_new_issues` asks again next
    # cycle and the MR will have settled by then.
    def defer_reentry(existing)
      log "Issue ##{existing.issue_iid}: MR !#{existing.mr_iid} is locked (merge in flight) → " \
          'waiting for the next cycle'
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

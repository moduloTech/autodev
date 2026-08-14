# frozen_string_literal: true

class PipelineMonitor
  # Ends the pipeline watch when the MR is no longer open — with the ending the
  # outcome deserves (Autodev #66).
  #
  # `poll_open_mr` routes every state that is not `opened` here, which used to
  # mean one ending for two opposite outcomes: the end label was posed
  # unconditionally, the row was left unflagged, and that was that. Merged, the
  # label is earned — the work is in the target branch. Closed without merging,
  # nothing was delivered, and on powerpanne/core the end label is
  # `Development::Awaiting Feature Review`: a human who rejected the work by
  # closing its MR put the ticket on the PM's board announced as ready to review.
  #
  # The flag was the worse half. `needs_attention` stayed false, which is exactly
  # the discriminator `dispatch_done_unassigned` selects on, so a rejected MR sat
  # in the `post_completion` population — the one guard Autodev #60 put there so a
  # deploy never runs on work autodev did not deliver. No project configures
  # `post_completion` today, so that was a latent deploy of rejected work.
  module MrStateChecker
    private

    # The split is on "was this delivered", not on GitLab's state vocabulary.
    # Only `merged` is a delivery; `closed`, `locked` (the transient mid-merge
    # state) and anything GitLab adds later are not. A poll that catches a
    # sub-second `locked` window therefore errs towards "a human should look",
    # which a reposed todo label undoes, rather than towards "ready for feature
    # review", which nothing undoes.
    def handle_mr_closed(issue, merge_request)
      state = merge_request.state
      log "MR !#{issue.mr_iid} is no longer open (#{state}), skipping pipeline check"
      return give_up_on_closed_mr(issue, state) unless state == 'merged'

      finish_merged_mr(issue, state)
    end

    def finish_merged_mr(issue, state)
      apply_label_done(issue.issue_iid)
      Issue.where(id: issue.id).update_all(finished_at: Time.current)
      issue.mr_closed!
      log_activity(issue, :mr_closed, mr_state: state)
      log "Issue ##{issue.issue_iid}: MR #{state} → done"
    end

    # The sixth route to the shared abandon point (Autodev #66), and the first one
    # that is not autodev's own verdict: a human decided. It still ends the same
    # way every other give-up does — `label_attention` instead of the end label
    # (and, unconfigured, no end label at all: the row keeps `label_doing`),
    # `needs_attention` so the row leaves the `post_completion` population and
    # shows up as needing an intervention, and the ticket handed back to its
    # author.
    #
    # Handing it back although a human just acted: assignment is ownership, not
    # notification. The person who closed the MR is not necessarily the ticket's
    # author, and a `done` row is outside `dispatch_unassignment`'s
    # `ACTIVE_STATUSES` sweep and outside the dormant audit's three arms — left on
    # autodev the ticket belongs to nobody, which is the invisibility Autodev #60
    # unified the reassignment to remove. The comment is then what explains a
    # handback the author did not ask for.
    #
    # `attention_reason` is its own value, like every other give-up's:
    # `dispatch_infra_recheck` selects exactly `stagnation_pipeline` and re-arms
    # the row, and a closed MR is a decision, not a deferral.
    #
    # No `detail:` — it renders through `web_errors_attention_detail` ("Job(s) en
    # cause : %{detail}"), so it may only carry a technical token, and there is no
    # failing job here. The state is in the log line above.
    def give_up_on_closed_mr(issue, state)
      log "Issue ##{issue.issue_iid}: MR #{state} without being merged → done, needs attention"
      abandon_issue(issue, :mr_closed_unmerged)
    end
  end
end

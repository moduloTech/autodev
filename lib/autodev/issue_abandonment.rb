# frozen_string_literal: true

# The single point at which autodev gives a ticket up (Autodev #60, item 2).
#
# Four call sites used to end a request themselves, and they had drifted apart on
# both axes that matter:
#
#   * `handle_stagnation`, `MrFixer#transition_to_done_stagnation!` and
#     `give_up_on_watch` wrote `status: 'done'` straight to the row. No AASM event
#     means no `transition` row in `activity_events`, so nothing in the activity
#     journal and nothing in the audit log — and none of the
#     `after_all_transitions` callbacks ran, which is exactly what produced the
#     stale `checking_pipeline_since` clock Autodev #53 had to fix by clearing the
#     column by hand at each of those sites.
#   * the review-round limit reassigned the ticket to its author; the other three
#     left it assigned to autodev. Nothing justified the difference, and leaving an
#     abandoned ticket on autodev is what made it invisible to everybody.
#
# So: one AASM event (`Issue#abandon`), one reassignment policy (always hand the
# ticket back to its author — an abandon means a human has to pick the work up),
# and since Autodev #63 one end label: `label_attention`, never `label_done`. On
# powerpanne `label_done` is `Development::Awaiting Feature Review`, so posing it
# on a give-up announced work as reviewed that nobody had reviewed — 28 such
# tickets landed on the review board during the 11/08/2026 incident. A project
# with no `label_attention` gets no end label at all and keeps `label_doing`.
#
# What is deliberately NOT unified is the *reason*. `attention_reason` stays
# per-site because `PollDispatcher#dispatch_infra_recheck` selects exactly
# `stagnation_pipeline` and re-arms the row: giving an expired watch or an
# exhausted review budget that reason would restart tickets autodev had just given
# up on. The GitLab comment and the activity line are keyed off the same reason
# for the same argument — three causes that need three different sentences.
#
# Including classes must have @client, @project_config, @project_path and @logger
# (i.e. anything that includes DangerClaudeRunner).
module IssueAbandonment
  private

  # `reason` is simultaneously the `attention_reason` column value, the
  # notification template key and the activity template key — they are the same
  # vocabulary by construction, and keeping them equal is what makes a new give-up
  # cause a one-line addition rather than a fourth chance to diverge.
  #
  # `detail` lands on `attention_detail` (rendered by
  # `web_errors_attention_detail`, so it may only carry a technical token) and on
  # the `%{detail}` template var — always, as `to_s`, because
  # `notify_stagnation_pipeline` references it and I18n raises on a *missing*
  # interpolation while silently ignoring an extra one. `vars` are the remaining
  # template vars (`days:` for the watch bound). Extra vars a template does not
  # reference cost nothing, so no site has to know the others' shapes.
  #
  # Returns false without any side effect when the row is not in an abandonable
  # state. That guard is not decoration: `whiny_transitions: false` answers an
  # impossible event with a silent no-op, and running the GitLab side effects
  # after one is the Autodev #61 bug.
  # rubocop:disable Naming/PredicateMethod -- the boolean says "the abandon
  # happened", which callers may need in order not to run their own follow-up
  # after a no-op transition; `abandon_issue?` would read as a question.
  def abandon_issue(issue, reason, detail: nil, **vars)
    return false unless fire_abandon(issue, reason)

    issue.update(finished_at: Time.current, needs_attention: true,
                 attention_reason: reason.to_s, attention_detail: detail)
    apply_label_attention(issue.issue_iid)
    announce_abandonment(issue, reason, vars.merge(detail: detail.to_s))
    true
  end

  def fire_abandon(issue, reason)
    return true if issue.abandon!

    log "Issue ##{issue.issue_iid}: abandon (#{reason}) skipped — row is '#{issue.status}', " \
        'not an abandonable state'
    false
  end
  # rubocop:enable Naming/PredicateMethod

  # The two user-facing sinks, and the reassignment one of them reports on. The
  # GitLab comment only claims a handback when the ticket actually changed hands.
  def announce_abandonment(issue, reason, template_vars)
    handed_back = reassign_to_author(issue)
    notify_localized(issue.issue_iid, reason, mr_url: issue.mr_url,
                                              suffix: (:abandon_reassigned if handed_back),
                                              **template_vars)
    log_activity(issue, reason, **template_vars)
  end
end

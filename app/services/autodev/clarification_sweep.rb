# frozen_string_literal: true

module Autodev
  # The arrears of Autodev #75, and only the arrears.
  #
  # `Issue::PROCESSABLE_STATES` makes the clarification pickup reachable again,
  # but only for a request autodev still *sees*: `dispatch_new_issues` asks GitLab
  # for the issues carrying a `labels_todo` label, and `SpecChecker#post_clarification`
  # does not repose one. On the 18/08/2026 production copy that left 9 of the 12
  # parked requests on `Development::Doing`, outside that population whatever the
  # router answers — the oldest waiting since 15/05/2026, all with a human answer
  # already on the thread.
  #
  # So this sweep reads the `issues` table instead of GitLab's label filter: the
  # label a ticket carries is irrelevant to it. That is also why it is a one-shot
  # `bin/rails autodev:recheck_clarifications` rather than a ninth dispatch pass.
  # Which pass should own `needs_clarification` from now on — repose a todo label
  # when the question is asked, or give the state a population of its own — moves
  # the ticket on the PM's board either way, so it is hers to arbitrate; a
  # scheduled pass added here would be that decision, taken quietly. Do not
  # promote this class into one.
  #
  # Reports by default. It transitions rows and writes a note on each ticket, so
  # the acting half is `APPLY=1`, the same shape as `ActivityEventCompaction`.
  class ClarificationSweep
    # For `externally_closed?` / `assigned_to_autodev?` only — the sweep never
    # closes a row, it only declines to act on one. Both read `@client`, which is
    # the same object for every project (the token is global), so it is set once
    # in `run`; neither reads `@path`.
    include ExternalState

    def initialize(config:, apply: false, out: $stdout, logger: nil)
      @config = config
      @apply = apply
      @out = out
      @logger = logger || NullLogger.new
    end

    # Swallows nothing into a verdict: a row whose thread GitLab could not serve
    # is counted `unreadable` and left exactly as it was — never `waiting`, which
    # is the one answer that would make a re-run skip it.
    def run
      tally = { examined: 0, answered: 0, waiting: 0, not_ours: 0, unreadable: 0 }
      @client = ::GitlabHelpers.build_gitlab_client(@config['gitlab_url'], @config['gitlab_token'])
      parked.find_each do |issue|
        tally[:examined] += 1
        examine(issue, tally)
      end
      report(tally)
      tally
    end

    private

    # Ordered oldest question first: on a partial run that is the order the
    # backlog should drain in, and it is the order the report reads best in.
    def parked
      ::Issue.where(status: 'needs_clarification').order(:clarification_requested_at)
    end

    # Order matters, and it is the same ranking `ExternalState` applies: a ticket
    # that went away or was reassigned is not ours whatever is written on its
    # thread, so ownership is asked before the answer is looked for.
    def examine(issue, tally)
      return not_ours(issue, tally) unless still_ours?(issue)

      resumer = ClarificationResume.new(client: @client, path: issue.project_path, logger: @logger)
      return still_waiting(issue, tally) unless resumer.answered?(issue)

      tally[:answered] += 1
      @apply ? apply!(issue, resumer) : say("#{label(issue)} — answered, would be re-queued")
    rescue StandardError => e
      tally[:unreadable] += 1
      say("#{label(issue)} — could not be read (#{e.class}: #{e.message}), left untouched")
    end

    # The filter `dispatch_new_issues` gets for free from its GitLab query and
    # this sweep does not: it selects from the `issues` table, which knows nothing
    # about who the ticket is assigned to now. Without this, a request a human
    # took back would be re-queued and then closed mid-clone by the next cycle's
    # `dispatch_unassignment` — one row on the 18/08/2026 copy is in exactly that
    # state (PowerPanne #14856, reassigned 11/06/2026).
    #
    # Reported, not closed. Whether a `needs_clarification` row that is no longer
    # ours should be closed is a decision about the live passes — no pass sweeps
    # this state today — and the arrears is not the place to take it.
    def still_ours?(issue)
      gl_issue = @client.issue(issue.project_path, issue.issue_iid)
      !externally_closed?(gl_issue) && assigned_to_autodev?(gl_issue)
    end

    def not_ours(issue, tally)
      tally[:not_ours] += 1
      say("#{label(issue)} — closed or reassigned on GitLab, left untouched")
    end

    def still_waiting(issue, tally)
      tally[:waiting] += 1
      say("#{label(issue)} — still waiting for an answer")
    end

    # Enqueued rather than merely transitioned: `pending` with no `next_retry_at`
    # is the orphan shape the codebase already knows (see `Issue.reset_for_retry!`),
    # and the ticket's label is `label_doing` for most of this population, so
    # `dispatch_new_issues` would not rediscover it. `:process` is the same action
    # the live path enqueues, and `IssueProcessJob`'s staleness guard accepts it
    # from `pending`.
    def apply!(issue, resumer)
      resumer.resume!(issue)
      ::IssueProcessJob.perform_later(issue.project_path, issue.issue_iid, :process)
      say("#{label(issue)} — answered, re-queued")
    end

    def label(issue)
      asked = issue.clarification_requested_at
      "#{issue.project_path}##{issue.issue_iid} (asked #{asked ? asked.strftime('%Y-%m-%d') : 'never'})"
    end

    def report(tally)
      say("examined #{tally[:examined]}, answered #{tally[:answered]}, waiting #{tally[:waiting]}, " \
          "not ours #{tally[:not_ours]}, unreadable #{tally[:unreadable]}")
      return if @apply

      say('dry run: nothing was changed (APPLY=1 to re-queue the answered requests)')
    end

    def say(msg) = @out.puts("[autodev:recheck_clarifications] #{msg}")

    # `ClarificationResume` logs through the poller's logger; a rake run has none
    # and its report is the `out` stream.
    class NullLogger
      %i[info warn error debug].each { |level| define_method(level) { |_msg, **_opts| nil } }
    end
  end
end

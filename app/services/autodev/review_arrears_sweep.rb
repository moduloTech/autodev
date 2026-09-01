# frozen_string_literal: true

module Autodev
  # The arrears of the revoked review token (Autodev #88), and only the arrears.
  #
  # 23 PowerPanne requests were given up between the 30/07 and the 14/08/2026
  # under `review_failures_exhausted`, every one of them with `review_count`
  # still at 0 — not one was ever reviewed, and all of them carry a merge
  # request. Nothing brings them back. The Autodev #75 sweep is written for
  # `needs_clarification` and does not see them; `dispatch_infra_recheck` selects
  # `stagnation_pipeline` and excludes every other give-up reason on purpose
  # (Autodev #53: an abandon is never re-armed automatically). Reposing the entry
  # label by hand does not work either, because `dispatch_new_issues` filters on
  # `assignee_id: <autodev>` and 22 of the 23 tickets were handed back to a human
  # by autodev's own `abandon_issue` → `reassign_to_author`.
  #
  # ## This is not a recurring pass, and here is why
  #
  # Two clocks would be reset by a pass that ran every cycle, and both of them
  # are safety nets (Autodev #74, recalled by #81):
  #
  #   * `Issue.without_activity_since` — read by `DormantAudit` and by the
  #     "Issues bloquées" card — asks whether a row has written anything lately.
  #     A pass that writes one line per cycle on the rows it *declines* keeps
  #     `recent` permanently non-empty, so those rows can never be selected again.
  #     Hence the rule below: a declined row gets a line on `out` and nothing else
  #     — no `ActivityLogger.post`, no GitLab note, no label edit.
  #   * `stamp_pipeline_watch!` is an `after_all_transitions` callback that
  #     rewrites `checking_pipeline_since` on every entry into `checking_pipeline`.
  #     A pass that re-fired the transition each cycle would restart the age clock
  #     forever and the `pipeline_watch_max_days` bound would never fire.
  #
  # So it is a one-shot rake, run by hand, like `ClarificationSweep` (#75) and
  # `ActivityEventCompaction` (#53). Do not extend this class into a scheduled
  # pass. The manual re-run is also the *spacing*: a human is in the loop at every
  # turn, which is what Autodev #53 asks of re-arming an abandon.
  #
  # A re-armed request does restamp `checking_pipeline_since`, and that is the
  # intent: it goes back out with 14 days of watch, and if it does not conclude it
  # ends on `pipeline_watch_expired` — a reason `dispatch_infra_recheck` does not
  # re-arm. That is the terminus.
  #
  # ## Three bounds, all of them written
  #
  #   * `apply:` — reports otherwise, the shape of the two sweeps above.
  #   * `limit:` — at most N re-armed per run (default 3 = `max_workers`, so a
  #     batch never queues behind itself). Applied after every filter, on the
  #     oldest-first order, and **only** under `apply:`; a report shows everything.
  #   * `include_author_handback:` — the ownership filter is `assigned_to_autodev?`
  #     verbatim unless the operator writes the flag. See `still_ours?`.
  # ClassLength / ParameterLists: one class per sweep, the shape `ClarificationSweep`
  # and `ActivityEventCompaction` already have — the selection, the four filters and
  # the report are one decision, and splitting them would hide the ranking between
  # them. The constructor's six keywords are the three bounds above plus the two
  # seams the tests need (`out`, `logger`); folding them into an options hash would
  # only move the list somewhere less visible.
  class ReviewArrearsSweep # rubocop:disable Metrics/ClassLength
    # For `externally_closed?` / `assigned_to_autodev?` only — the sweep never
    # closes a row, it only declines to act on one. Both read `@client`, the same
    # object for every project (the token is global), so it is set once in `run`;
    # neither reads `@path`.
    include ExternalState

    # `config/queue.yml`'s `max_workers`, and the only global concurrency ceiling
    # that exists. A batch equal to the thread count never queues behind itself.
    # Measured cost of one re-armed request: 1 to ~60 danger-claude calls, 1 to 4
    # CI pipelines, 10 to 30 GitLab notes — 23 at once is the shape of the 11/08
    # incident (33 rows unblocked together, 486 comments in two hours).
    DEFAULT_LIMIT = 3

    # Every verdict a row can leave with, and the counter each one raises. They
    # are disjoint: `unreadable` is not one of them, it is the absence of one.
    VERDICTS = { eligible: :eligible, waiting: :waiting, already_merged: :already_merged,
                 mr_closed: :mr_closed, unknown_state: :unknown_state,
                 already_swept: :already_swept, not_ours: :not_ours }.freeze

    # `payload_json` is always `JSON.generate(from:, to:, event:)`
    # (`Issue#emit_activity_event!`), so the event name is a literal JSON
    # fragment. `_` is a LIKE wildcard, hence the escapes.
    REENTRY_MARKER = '%"event":"reenter\\_to\\_check\\_pipeline"%'

    # Each of these leaves the row exactly as it is. `already_merged`: the work is
    # delivered, and changing the label would be a verdict on a delivery nobody
    # recorded. `mr_closed`: `attention_reason` is NOT rewritten — antedating an
    # Autodev #66 verdict onto an Autodev #63 abandon falsifies the audit trail.
    # `waiting`: nothing is concluded and nothing is spent (Autodev #69 / #72).
    MR_VERDICT_REASON = {
      already_merged: 'the merge request is merged, left untouched',
      mr_closed: 'the merge request is closed, left untouched (attention_reason unchanged)',
      waiting: 'GitLab is mid-merge, nothing concluded and no slot spent',
      unknown_state: 'the merge request state carries no known verdict, left untouched'
    }.freeze

    def initialize(config:, apply: false, limit: DEFAULT_LIMIT, # rubocop:disable Metrics/ParameterLists
                   include_author_handback: false, out: $stdout, logger: nil)
      @config = config
      @apply = apply
      @limit = limit
      @include_author_handback = include_author_handback
      @out = out
      @logger = logger || NullLogger.new
    end

    # Swallows nothing into a verdict: a row GitLab could not answer for is
    # counted `unreadable` and left exactly as it was — no transition, no label,
    # no reassignment, no note, no counter — and it consumes no slot in the batch.
    def run
      tally = VERDICTS.values.to_h { |key| [key, 0] }
                             .merge(examined: 0, rearmed: 0, deferred: 0, unreadable: 0)
      @client = ::GitlabHelpers.build_gitlab_client(@config['gitlab_url'], @config['gitlab_token'])
      @budget = @apply ? @limit : nil
      abandoned.each do |issue|
        tally[:examined] += 1
        examine(issue, tally)
      end
      report(tally)
      tally
    end

    private

    # `status` is a text column driven by AASM and `attention_reason` a free
    # string written at `Reviewer#give_up_reviewing`; there is no enum to lean on.
    #
    # `review_count: 0` is the load-bearing clause, not decoration: it is the
    # difference between "the review never happened" and "the review ran and the
    # budget was spent later". Eight requests already left this population through
    # a manual gesture and carry a 1 — nothing in the database can now tell a
    # skipped review from a completed one there, so they stay out.
    #
    # No project filter, the same choice as Autodev #75: the population is what it
    # is, not what was investigated.
    #
    # Ordered oldest give-up first, and loaded whole with `.each` rather than
    # `find_each`: Rails 8 discards a scope's order inside `find_each`, forces
    # primary-key order and only logs a warning, so the declared order and the
    # real one disagreed in silence. On a capped run the order IS the policy —
    # the oldest arrears drain first — so an `each` that becomes a `find_each`
    # silently breaks the promise. Pinned by a test.
    def abandoned
      ::Issue.where(status: 'done', needs_attention: true,
                    attention_reason: 'review_failures_exhausted')
             .where(review_count: 0)
             .where.not(mr_iid: nil)
             .order(:finished_at)
    end

    # The boundary is the row, not the run (Autodev #67 / #75): one unreadable
    # ticket must not take the rest of the arrears down with it.
    #
    # Order is a ranking. The marker is a DB read and decides on its own, so it
    # comes first and saves two API calls. Ownership is next: a ticket that went
    # away or belongs to somebody else is not ours whatever its MR says. The MR
    # state is last, because it is the only question that costs a second call.
    def examine(issue, tally)
      return decline(tally, :already_swept, swept_line(issue)) if swept_before?(issue)

      gl_issue = read_issue(issue)
      return decline(tally, :not_ours, "#{label(issue)} — #{ownership(gl_issue)}") unless still_ours?(issue, gl_issue)

      consider(issue, tally, read_mr(issue))
    rescue StandardError => e
      unreadable(issue, tally, e)
    end

    def read_issue(issue)
      ::GitlabHelpers.answer(:issue) { @client.issue(issue.project_path, issue.issue_iid) }
    end

    def swept_line(issue) = "#{label(issue)} — re-armed once already and given up again, left untouched"

    def unreadable(issue, tally, error)
      tally[:unreadable] += 1
      say("#{label(issue)} — could not be read (#{error.class}: #{error.message}), left untouched; " \
          'a new run will pick it up')
    end

    # The report line is built BEFORE anything is written, so a merge request that
    # cannot be described raises with the row still untouched, instead of leaving
    # it re-armed and counted `unreadable` at the same time.
    def consider(issue, tally, merge_req)
      verdict = mr_verdict(merge_req)
      described = describe(issue, merge_req)
      return decline(tally, verdict, "#{described} — #{MR_VERDICT_REASON.fetch(verdict)}") unless verdict == :eligible

      tally[:eligible] += 1
      return say("#{described} — never re-armed, would go back to the pipeline check (APPLY=1)") unless @apply

      rearm(issue, tally, described)
    end

    # The merge request's real state, re-read now and sorted through the one
    # definition of "does this state carry a verdict" (`MrState`, Autodev #72) —
    # `when 'locked'` written by hand is exactly the fault that ticket repaired.
    # An allow-list, never a deny-list: a state GitLab adds tomorrow is unknown
    # and nothing is done to it.
    def mr_verdict(merge_req)
      state = ::GitlabHelpers.field(merge_req, :state)
      return :waiting if ::MrState.transient?(state)

      case state
      when 'opened' then :eligible
      when 'merged' then :already_merged
      when 'closed' then :mr_closed
      else :unknown_state
      end
    end

    def decline(tally, verdict, line)
      tally[VERDICTS.fetch(verdict)] += 1
      say(line)
      nil
    end

    # Exactly two writes on a re-armed row, and both are the audit trail: the
    # `transition` row the AASM event emits, and the activity entry
    # `reenter_via_pipeline_check` posts. Nothing else, ever.
    #
    # The reassignment comes first because it is the reversible half: a failed
    # `edit_issue` raises before the transition, so the row stays `done` with
    # autodev as assignee, which no pass acts on. The other order would leave a
    # `checking_pipeline` row assigned to a human, and `dispatch_unassignment`
    # closes exactly that at the next cycle — with a GitLab comment on somebody
    # else's ticket.
    def rearm(issue, tally, described)
      return defer(tally, described) unless slot_available?

      @budget -= 1
      reclaim(issue)
      router_for(issue.project_path).resume_never_reviewed(issue, @client)
      tally[:rearmed] += 1
      say("#{described} — never re-armed, back to the pipeline check")
    end

    def defer(tally, described)
      tally[:deferred] += 1
      say("#{described} — eligible, deferred to a later run (LIMIT=#{@limit} reached)")
    end

    def slot_available?
      @budget.nil? || @budget.positive?
    end

    # `dispatch_unassignment` sweeps `ACTIVE_STATUSES`, which contain
    # `checking_pipeline`. A row re-armed without this is found unassigned at the
    # next cycle and closed, with a comment posted on a human's ticket — which is
    # legitimate ONLY on the rows the ownership filter accepted.
    def reclaim(issue)
      @client.edit_issue(issue.project_path, issue.issue_iid,
                         assignee_ids: [::GitlabHelpers.current_user_id(@client)])
    end

    # `apply_label_doing` runs inside `reenter_via_pipeline_check` and it is
    # load-bearing: it strips `Awaiting CR` / `Awaiting Feature Review` / `StandBy`
    # (7 of the 23 carry one), and without that `stop_on_handover` reads a
    # `workflow_moved` and closes the row. `manage_labels` skips a write that
    # would change nothing, so the 15 already on `Doing` emit no label event.
    def router_for(path)
      ::PollRouter.new(config: @config, project_config: project_config(path), logger: @logger,
                       token: @config['gitlab_token'], pool: nil)
    end

    def project_config(path)
      @project_configs ||= ::Project.runtime_configs(@config['projects']).index_by { |cfg| cfg['path'] }
      @project_configs[path] || raise(::ConfigError, "no project configuration for #{path}")
    end

    # Strict by default, and the strictness is the point (Autodev #75's filter
    # does not transfer). There the population was still assigned to autodev, so
    # `assigned_to_autodev?` restored a true ownership. Here the unassignment is
    # AUTODEV's own write — `abandon_issue` → `announce_abandonment` →
    # `reassign_to_author` — so the strict rule declines 22 of the 23 rows it was
    # written to rescue. One is eligible today, which makes the pilot batch free.
    #
    # The permissive rule is therefore behind a flag, and it is narrow: the ticket
    # must be assigned to its author and to nobody else — exactly where
    # `reassign_to_author` put it — with no human comment and no workflow-label
    # move by somebody else since `finished_at`. A permissive gesture is always a
    # written one.
    #
    # `human_comment_since?` raises on an unreadable thread (Autodev #67), so an
    # outage declines nothing into a verdict. `LabelHandover#moved_since?` keeps
    # that class's own rule instead — an unreadable event list reads as "nobody
    # moved it" — which is worth knowing when running with the flag on.
    def still_ours?(issue, gl_issue)
      return false if externally_closed?(gl_issue)
      return true if assigned_to_autodev?(gl_issue)

      @include_author_handback && untouched_handback?(issue, gl_issue)
    end

    def untouched_handback?(issue, gl_issue)
      return false unless handed_back_to_author?(issue, gl_issue)
      return false if ::GitlabHelpers.human_comment_since?(@client, issue.project_path,
                                                           issue.issue_iid, issue.finished_at)

      !handover(issue).moved_since?(gl_issue, issue.issue_iid, issue.finished_at)
    end

    def handed_back_to_author?(issue, gl_issue)
      author = issue.issue_author_id
      !author.nil? && assignee_ids(gl_issue) == [author]
    end

    def handover(issue)
      LabelHandover.new(client: @client, path: issue.project_path,
                        project_config: project_config(issue.project_path), logger: @logger)
    end

    def assignee_ids(gl_issue)
      Array(::GitlabHelpers.field(gl_issue, :assignees)).map { |a| ::GitlabHelpers.field(a, :id) }
    end

    def ownership(gl_issue)
      return 'the ticket is closed on GitLab, left untouched' if externally_closed?(gl_issue)

      ids = assignee_ids(gl_issue)
      return 'nobody is assigned on GitLab, left untouched' if ids.empty?

      "assigned to user #{ids.join(', ')}, left untouched"
    end

    # Has this request already been through a re-arm? Read from `activity_events`
    # rather than a new column: a `transition` row is never purged (`transition`
    # is not in `ActivityEvent::MACHINERY_KINDS`), so the record is already there
    # and a migration would be inventing a second one.
    #
    # Without this, a request re-armed and then given up again comes back into the
    # population with `review_count` still at 0, and the sweep re-arms it every
    # other run forever.
    #
    # Note what it is NOT: a comparison against `finished_at`. The design called
    # for one, and it cannot work — `Reviewer#give_up_reviewing` rewrites
    # `finished_at` to the moment of the *second* abandon, which is by
    # construction later than the re-arm being looked for, so the comparison would
    # answer "never re-armed" on exactly the rows it exists to catch. In this
    # population (`review_count == 0`) the row's own journey to `done` never went
    # through `reenter_to_check_pipeline`, so the presence of that event is
    # already the fact.
    def swept_before?(issue)
      ::ActivityEvent.where(issue_id: issue.id, kind: 'transition')
                     .where('payload_json LIKE ? ESCAPE ?', REENTRY_MARKER, '\\')
                     .exists?
    end

    def read_mr(issue)
      ::GitlabHelpers.answer(:merge_request) do
        @client.merge_request(issue.project_path, issue.mr_iid)
      end
    end

    # The merge request's facts travel to the operator and none of them is a
    # filter. A review reads a diff; it does not need a mergeable merge request,
    # and a conflict is precisely what a human has to be told about. But
    # `detailed_merge_status: "checking"` means GitLab has not finished computing,
    # so `has_conflicts: false` is not a fact there — the Autodev #67 rule applied
    # to a field rather than to a call.
    def describe(issue, merge_req)
      status = ::GitlabHelpers.field(merge_req, :detailed_merge_status)
      "#{label(issue)} MR !#{issue.mr_iid} state #{::GitlabHelpers.field(merge_req, :state)}, " \
        "merge status #{status || 'unknown'}, conflicts #{conflicts(merge_req, status)}"
    end

    def conflicts(merge_req, status)
      value = ::GitlabHelpers.field(merge_req, :has_conflicts)
      return 'unknown' if value.nil? || status.to_s == 'checking'

      value ? 'yes' : 'no'
    end

    def label(issue)
      at = issue.finished_at
      "#{issue.project_path}##{issue.issue_iid} (given up #{at ? at.strftime('%Y-%m-%d') : 'never'})"
    end

    def report(tally)
      say("examined #{tally[:examined]}, eligible #{tally[:eligible]} " \
          "(re-armed #{tally[:rearmed]}, deferred: #{tally[:deferred]}), " \
          "waiting #{tally[:waiting]}, already merged #{tally[:already_merged]}, " \
          "mr closed #{tally[:mr_closed]}, unknown state #{tally[:unknown_state]}, " \
          "already swept #{tally[:already_swept]}, not ours #{tally[:not_ours]}, " \
          "unreadable #{tally[:unreadable]}")
      report_remaining(tally)
      return if @apply

      say("dry run: nothing was changed (APPLY=1 to re-arm the eligible requests, #{@limit} per run)")
    end

    def report_remaining(tally)
      return unless tally[:deferred].positive?

      say("#{tally[:deferred]} eligible request(s) left outside this batch — re-run to take the next " \
          "#{@limit}; each run puts a human back in the loop, which is the spacing")
    end

    def say(msg) = @out.puts("[autodev:recheck_review_arrears] #{msg}")

    # `PollRouter` and `LabelHandover` log through the poller's logger; a rake run
    # has none and its report is the `out` stream.
    class NullLogger
      %i[info warn error debug].each { |level| define_method(level) { |_msg, **_opts| nil } }
    end
  end
end

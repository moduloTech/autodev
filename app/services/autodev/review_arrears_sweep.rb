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
  # by autodev's own `abandon_issue` → `hand_ticket_back`.
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
  #     batch never queues behind itself; ceiling 10, see `LIMIT_SPEC`). Applied
  #     after every filter, on the oldest-first order, and **only** under
  #     `apply:`; a report shows everything.
  #   * `include_author_handback:` / `include_human_held:` — the ownership filter
  #     is `assigned_to_autodev?` verbatim unless the operator writes one of the
  #     two flags, which widen it in that order. See `widened_to?`.
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

    # `LIMIT` is the only number an operator types into this sweep, so it gets
    # what every other numeric setting gets (Autodev #58): a type AND a range,
    # from one declaration. It had only the type, and every degenerate value fell
    # on the safe side by luck — absent, `""`, `"abc"`, `"3.7"` all read as the
    # default 3, `"0"` and `"-1"` re-armed nothing — while `LIMIT=30`, one
    # keystroke away from 3, re-armed the whole 23-row arrears in a single run:
    # exactly the 11/08/2026 shape `DEFAULT_LIMIT` cites as its reason to exist.
    #
    # Ceiling 10: three times the default, so an operator who deliberately wants
    # to go faster can, and under half the arrears, so no single run can ever
    # drain them — the manual re-run is the spacing. `max_workers` is 3 anyway, so
    # a larger batch only queues behind itself. Floor 1: `APPLY` is what turns the
    # writes off, so `LIMIT=0` is a typo and not a policy.
    LIMIT_SPEC = ::NumericSettings::Spec.new(field: 'LIMIT', min: 1, max: 10)

    # `LIMIT` as the rake task reads it. Absent or blank means "the default";
    # anything else must be an integer inside the declared range, and a value
    # that is not is refused before a single row is examined — silently doing
    # something other than what the operator typed is how the ceiling came to be
    # missing in the first place.
    def self.limit_from(raw)
      return DEFAULT_LIMIT if raw.nil? || raw.to_s.strip.empty?

      value = ::NumericSettings.integer(raw)
      return value if value && LIMIT_SPEC.cover?(value)

      raise ::ConfigError,
            "LIMIT must be an integer between #{LIMIT_SPEC.min} and #{LIMIT_SPEC.max}, got: #{raw.inspect}"
    end

    # One row's established facts, gathered before anything is written: the DB
    # row, the ticket as GitLab has it, the assignee ids it had *before* the sweep
    # touched it (what a half-finished re-arm has to be able to restore), those
    # assignees' usernames, and the router — built up front so a project missing
    # from the configuration raises while the row is still untouched.
    #
    # The usernames are captured here rather than read back off `gl_issue` when
    # the notice is written, because by then the assignment has been replaced:
    # what a takeover has to name is who held the ticket BEFORE it, and that is a
    # fact of the same vintage as `assignees`.
    Row = Struct.new(:issue, :gl_issue, :assignees, :usernames, :router)

    # The two GitLab facts a re-arm establishes, named for the report. The third
    # write is the AASM event, and it is local.
    WORKING_LABEL = 'the working label is posed'
    ASSIGNMENT = 'autodev is back on the ticket'

    # Every verdict a row can leave with, and the counter each one raises. They
    # are disjoint, and two counters are deliberately NOT in here because they
    # are the absence of a verdict rather than one: `unreadable` (nothing could be
    # established about the row, nothing was written, no slot spent) and
    # `incomplete` (the re-arm started and did not finish — the slot is spent,
    # and the report names which of its writes landed).
    VERDICTS = { eligible: :eligible, waiting: :waiting, already_merged: :already_merged,
                 mr_closed: :mr_closed, mr_conflicted: :mr_conflicted,
                 unknown_state: :unknown_state,
                 already_swept: :already_swept, not_ours: :not_ours }.freeze

    # Each of these leaves the row exactly as it is. `already_merged`: the work is
    # delivered, and changing the label would be a verdict on a delivery nobody
    # recorded. `mr_closed`: `attention_reason` is NOT rewritten — antedating an
    # Autodev #66 verdict onto an Autodev #63 abandon falsifies the audit trail.
    # `waiting`: nothing is concluded and nothing is spent (Autodev #69 / #72).
    MR_VERDICT_REASON = {
      already_merged: 'the merge request is merged, left untouched',
      mr_closed: 'the merge request is closed, left untouched (attention_reason unchanged)',
      mr_conflicted: 'the merge request has conflicts, left untouched ' \
                     '(re-arming it takes the ticket to run a correction loop on work that cannot land)',
      waiting: 'GitLab is mid-merge, nothing concluded and no slot spent',
      unknown_state: 'the merge request state carries no known verdict, left untouched'
    }.freeze

    def initialize(config:, apply: false, limit: DEFAULT_LIMIT, # rubocop:disable Metrics/ParameterLists
                   include_author_handback: false, include_human_held: false,
                   out: $stdout, logger: nil)
      @config = config
      @apply = apply
      @limit = limit
      @include_author_handback = include_author_handback
      @include_human_held = include_human_held
      @out = out
      @logger = logger || NullLogger.new
    end

    # Swallows nothing into a verdict, and the two ways of not reaching one are
    # kept apart:
    #
    #   * `unreadable` — GitLab (or the configuration) could not answer for the
    #     row, so it is left exactly as it was: no transition, no label, no
    #     reassignment, no note, no counter, and no slot spent. A later run picks
    #     it up unchanged;
    #   * `incomplete` — the re-arm started and did not finish. The slot IS spent,
    #     the report names which of its writes landed and which were undone, and
    #     the row waits for a human. Never described as "left untouched", which is
    #     what an `unreadable` row is.
    def run
      tally = new_tally
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

    def new_tally
      VERDICTS.values
              .to_h { |key| [key, 0] }
              .merge(examined: 0, rearmed: 0, deferred: 0, unreadable: 0, incomplete: 0)
    end

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
    # comes first and saves two API calls. The router comes next, because it is
    # local and because building it is what resolves the project configuration:
    # it used to be built inside `rearm`, AFTER `reclaim`, so a row whose project
    # had left the configuration was reassigned to autodev and only then raised.
    # Ownership follows: a ticket that went away or belongs to somebody else is
    # not ours whatever its MR says. The MR state is last, the only question that
    # costs a second call.
    #
    # Everything in here reads; nothing writes. That is what makes the promise
    # `unreadable` carries — "left untouched, a new run will pick it up" — true.
    def examine(issue, tally)
      return decline(tally, :already_swept, swept_line(issue)) if swept_before?(issue)

      router = router_for(issue.project_path)
      gl_issue = read_issue(issue)
      verdict = ownership_verdict(issue, gl_issue)
      return decline(tally, :not_ours, "#{label(issue)} — #{ownership(gl_issue, verdict)}") unless verdict == :ours

      consider(Row.new(issue, gl_issue, assignee_ids(gl_issue), usernames_of(gl_issue), router),
               tally, read_mr(issue))
    rescue StandardError => e
      unexaminable(issue, tally, e)
    end

    def read_issue(issue)
      ::GitlabHelpers.answer(:issue) { @client.issue(issue.project_path, issue.issue_iid) }
    end

    def swept_line(issue) = "#{label(issue)} — already re-armed by this sweep and given up again, left untouched"

    # "Could not be examined" rather than "could not be read": a project missing
    # from the configuration reaches here too, and it is not a failed read. What
    # every case in here shares is the part that matters — nothing was written.
    def unexaminable(issue, tally, error)
      tally[:unreadable] += 1
      say("#{label(issue)} — could not be examined (#{error.class}: #{error.message}), " \
          'nothing was written and no slot spent; a new run will pick it up')
    end

    # The report line is built BEFORE anything is written, so a merge request that
    # cannot be described raises with the row still untouched, instead of leaving
    # it re-armed and counted `unreadable` at the same time.
    def consider(row, tally, merge_req)
      verdict = mr_verdict(merge_req)
      described = describe(row.issue, merge_req)
      return decline(tally, verdict, "#{described} — #{MR_VERDICT_REASON.fetch(verdict)}") unless verdict == :eligible

      tally[:eligible] += 1
      return say("#{described} — never re-armed, would go back to the pipeline check (APPLY=1)") unless @apply

      rearm(row, tally, described)
    end

    # The merge request's real state, re-read now and sorted through the one
    # definition of "does this state carry a verdict" (`MrState`, Autodev #72) —
    # `when 'locked'` written by hand is exactly the fault that ticket repaired.
    # An allow-list, never a deny-list: a state GitLab adds tomorrow is unknown
    # and nothing is done to it.
    #
    # Autodev #105 refines `opened`, and only `opened`: a merge request that
    # cannot merge is not eligible. The fields were already being read — `describe`
    # prints `conflicts yes` on the line above this decision — the decision just
    # did not look at them.
    def mr_verdict(merge_req)
      state = ::GitlabHelpers.field(merge_req, :state)
      return :waiting if ::MrState.transient?(state)

      case state
      when 'opened' then opened_verdict(merge_req)
      when 'merged' then :already_merged
      when 'closed' then :mr_closed
      else :unknown_state
      end
    end

    # `detailed_merge_status: "checking"` means GitLab has not finished computing,
    # so `has_conflicts: false` is not a fact there — the Autodev #67 rule that
    # `conflicts` already applies to this field, applied to the decision as well.
    # `:waiting` rather than `:eligible`: a read that could not answer is not
    # permission to take somebody's ticket, and the next run asks again for free.
    def opened_verdict(merge_req)
      status = ::GitlabHelpers.field(merge_req, :detailed_merge_status).to_s
      return :waiting if status == 'checking'
      return :mr_conflicted if status == 'conflict'
      return :mr_conflicted if ::GitlabHelpers.field(merge_req, :has_conflicts)

      :eligible
    end

    def decline(tally, verdict, line)
      tally[VERDICTS.fetch(verdict)] += 1
      say(line)
      nil
    end

    # Exactly two rows of audit trail on a re-armed issue, and both are written
    # by the reentry: the `transition` row the AASM event emits and the activity
    # entry `reenter_via_pipeline_check` posts. Nothing else, ever.
    #
    # Three writes get it there, and the order is what makes each partial outcome
    # survivable.
    #
    #   1. **the working label**, verified by reading the ticket back. It has to
    #      be right BEFORE the row can enter `dispatch_unassignment`'s population
    #      at all: that pass runs before `dispatch_pipelines`, `checking_pipeline`
    #      is in its `ACTIVE_STATUSES`, and a ticket still carrying its end label
    #      is read as a `workflow_moved` handover — the row closed and a comment
    #      posted blaming a human for a move nobody made.
    #   2. **the assignment**, which is what stops that same pass from closing the
    #      row for being unassigned. Undone if the third write fails: a `done` row
    #      assigned to autodev is swept by nothing, and the next default run would
    #      accept it on `assigned_to_autodev?` alone — the widenings the two flags
    #      exist to gate, leaking through the gate.
    #   3. **the AASM event**, local, and the only one after which the row is in
    #      `checking_pipeline`.
    #
    # The slot is spent as soon as the writes are attempted, and stays spent even
    # when none of them landed: a run that has started writing on a row is a run
    # something went wrong in, and the batch is a bound on how much of that a
    # single invocation may do. Only a row the sweep never started writing on
    # keeps its slot, which is why every read — and the project-configuration
    # lookup — lives in `examine`, above the decrement.
    def rearm(row, tally, described)
      return defer(tally, described) unless slot_available?

      @budget -= 1
      landed = []
      begin
        write_rearm(row, landed)
      rescue StandardError => e
        return incomplete(row, tally, described, error: e, landed: landed)
      end
      tally[:rearmed] += 1
      say("#{described} — never re-armed, back to the pipeline check")
    end

    def write_rearm(row, landed)
      repose_working_label(row)
      landed << WORKING_LABEL
      reclaim(row, landed)
      row.router.resume_never_reviewed(row.issue, @client)
    end

    # Not `unreadable`, and the report must never conflate the two: the slot is
    # spent and the row may have been written to, so "left untouched; a new run
    # will pick it up" would be false on both counts. The line therefore names
    # what landed instead of summarising it, and `no write landed` is only ever
    # said when the first write is the one that failed — GitLab replaces the whole
    # label list in one call, so there is no half-written label state to describe.
    def incomplete(row, tally, described, error:, landed:)
      tally[:incomplete] += 1
      say("#{described} — re-arm incomplete (#{error.class}: #{error.message}); " \
          "#{landed.empty? ? 'no write landed' : "landed: #{landed.join(', ')}"}" \
          "#{undo(row, landed)}; the row is still done, its slot is spent, a human has to look")
      nil
    end

    def undo(row, landed)
      return '' unless landed.include?(ASSIGNMENT)
      return '; the assignment has been handed back' if restore_assignees(row)

      '; the assignment could NOT be handed back, autodev is still on the ticket'
    end

    # The assignee list exactly as `examine` read it, from `Row` rather than from
    # `gl_issue`: the ticket has been written to since.
    # The column goes with the assignment: a takeover that was undone displaced
    # nobody, and leaving it set would send a later give-up's handback to somebody
    # who is holding the ticket already (`IssueNotifier#handback_target`).
    def restore_assignees(row)
      @client.edit_issue(row.issue.project_path, row.issue.issue_iid, assignee_ids: row.assignees)
      row.issue.update(displaced_assignee_id: nil)
      true
    rescue StandardError => e
      @logger.error("Failed to hand ##{row.issue.issue_iid} back to its assignees: #{e.message}",
                    project: row.issue.project_path)
      false
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
    #
    # Autodev is **added** to the assignees, never substituted for them. The
    # strict filter is `assigned_to_autodev?`, an `.any?`, so a ticket assigned to
    # autodev *and* to a human passes it — and `assignee_ids: [<autodev>]` then
    # took that human off the ticket with no comment and no trace anywhere autodev
    # writes.
    #
    # **The union does not work on our instance** (Autodev #98). Multiple
    # assignees are a Premium feature and source.modulotech.fr answers
    # `enterprise: false`: `assignee_ids: [human, autodev]` is accepted — 200, no
    # exception — and only the first survives, with no system note at all when
    # that first one was already there. The observation that "no production row is
    # co-assigned today" was not a coincidence to note: no row *can* be, so this
    # correction has never corrected anything.
    #
    # Measured on powerpanne/core#16224, 02/09/2026: labels written, transition
    # fired, no assignment event anywhere, and `dispatch_unassignment` closed the
    # row 94 seconds later with a comment telling a human he had unassigned
    # autodev. He had not. That is, word for word, the harm the paragraph above
    # says this method prevents.
    #
    # So autodev **takes** the ticket instead, and three things make that
    # defensible rather than the silent theft the paragraph above rejects:
    #
    #   * it only happens on a row the ownership filter accepted, and the filter
    #     that accepts a human-held row is `include_human_held:` — an explicit
    #     flag, off by default, whose report says whose ticket would be taken
    #     before anything is written;
    #   * it is **said**, on the ticket, naming the person it was taken from and
    #     why (`announce_takeover`). What made the old substitution wrong was that
    #     it happened "with no comment and no trace anywhere autodev writes", not
    #     that it happened;
    #   * it is **given back to them** and not to the ticket's author, which is a
    #     different person on 4 of the 20 rows of this population and, on one of
    #     them, a deactivated account. `displaced_assignee_id` records who, and
    #     `IssueNotifier#handback_target` reads it.
    #
    # And the write is **read back**, exactly as the label write below is, because
    # it is the one write GitLab Community can accept and ignore.
    #
    # Returns the assignee list it wrote, or nil when it wrote nothing — the
    # shape of `manage_labels`, and for the same reason: a write that would change
    # nothing is not made, and a row already assigned to autodev alone is exactly
    # that case.
    # `landed` is pushed by the write, not by this method's return value
    # (Autodev #97/#98 review). Three things can still raise after `edit_issue`
    # has landed — the read-back below, the `displaced_assignee_id` write, and the
    # notice — and every one of them used to leave the fact unrecorded, so `undo`
    # did not restore and the human was off the ticket with no notice, no trace
    # and no handback. The row then carried autodev alone, which the next
    # **default** run accepts on `assigned_to_autodev?`: the widening flags
    # leaking through the gate they exist to be.
    #
    # `landed` therefore records what was **written**, which is the question
    # `undo` asks. The one case where that over-records is `AssignmentNotLanded`
    # — GitLab accepted the call and ignored it — and the restore is then a write
    # of the list the ticket already carries: no change, no system note, measured
    # on powerpanne/core#16224. Harmless, and cheaper than a second vocabulary for
    # "written but not confirmed".
    def reclaim(row, landed)
      autodev = ::GitlabHelpers.current_user_id(@client)
      return nil if row.assignees == [autodev]

      @client.edit_issue(row.issue.project_path, row.issue.issue_iid, assignee_ids: [autodev])
      landed << ASSIGNMENT
      unless assignees_now(row).include?(autodev)
        raise AssignmentNotLanded, 'autodev is not among the assignees after the assignment write'
      end

      record_takeover(row, autodev)
      [autodev]
    end

    # Written after the read-back, so nothing is recorded about a takeover that
    # did not happen. `displaced_assignee_id` stays NULL when autodev displaced
    # nobody (an unassigned ticket), and the handback then falls back to the
    # author exactly as it always did.
    def record_takeover(row, autodev)
      displaced = (row.assignees - [autodev]).first
      return unless displaced

      row.issue.update(displaced_assignee_id: displaced)
      announce_takeover(row, displaced)
    end

    # The comment is the whole difference between taking a ticket and quietly
    # removing somebody from it. Posted as a plain note rather than through
    # `IssueNotifier`, which is a mixin of the danger-claude runner this sweep is
    # not; the locale is the row's, like every other message autodev writes.
    #
    # Addressed by `username` — a GitLab mention is `@handle`, and `@42` names
    # nobody — read off the payload `examine` already fetched. It falls back to
    # the numeric id rather than dropping the address, because a message that
    # cannot name its reader is still owed to them.
    def announce_takeover(row, displaced)
      @client.create_issue_note(row.issue.project_path, row.issue.issue_iid,
                                takeover_notice(row, displaced))
    rescue ::Gitlab::Error::ResponseError => e
      # The takeover itself has landed and been read back; failing to announce it
      # must not undo it. It is reported instead, and loudly, because a ticket
      # that changed hands in silence is the defect this method exists to avoid.
      @logger.error("Failed to announce the takeover of ##{row.issue.issue_iid}: #{e.message}",
                    project: row.issue.project_path)
      say("#{label(row.issue)} — TAKEN OVER WITHOUT A NOTICE (#{e.message}); tell user #{displaced} by hand")
    end

    def takeover_notice(row, displaced)
      ::Locales.t(:arrears_takeover,
                  locale: (row.issue.locale || 'fr').to_sym,
                  tag: "**autodev** (v#{::Autodev::VERSION})",
                  user: row.usernames[displaced] || displaced,
                  mr_url: row.issue.mr_url)
    end

    # Read back from GitLab rather than from `row.assignees`, which is what
    # `examine` saw before any write.
    def assignees_now(row)
      Array(::GitlabHelpers.field(read_issue(row.issue), :assignees))
        .map { |assignee| ::GitlabHelpers.field(assignee, :id) }
    end

    # `apply_label_doing` → `LabelManager#manage_labels` answers a GitLab error
    # with a log line and `[]`, so an exception is NOT what a failed label write
    # looks like from here. The fact is therefore read back rather than assumed —
    # the Autodev #79 rule ("autodev never resolves a discussion it has not
    # verified") applied to a label.
    #
    # Two facts have to be true, not one.
    #
    # `label_doing` sitting on the ticket is the first. The second is that no
    # foreign value is left beside it in autodev's own scope — `Development::
    # Awaiting CR`, which five production rows carry. This used to be read as
    # GitLab's doing: one value per scoped-label key, applied to the write that
    # poses `Development::Doing` beside it. **GitLab does not do that** — it is a
    # Premium feature and source.modulotech.fr answers `enterprise: false`, so the
    # two values coexisted on powerpanne/core#16224 on 02/09/2026 (Autodev #98).
    #
    # `LabelManager#manage_labels` now clears the scope itself, via
    # `LabelHandover#scope_residue`. Which is exactly why the residue is verified
    # here too rather than assumed: the ticket showing two states of one scope is
    # what makes `LabelHandover#suspect` answer `workflow_moved` on the row this
    # sweep just re-armed, and the next cycle closes it as a handover.
    #
    # Two configurations have nothing to read back and are let through: a project
    # that declares no `labels_todo` (`apply_label_doing` returns before writing
    # anything at all) and one that declares no `label_doing` (it removes the
    # labels it knows and poses none, so there is no label whose presence is the
    # fact). Neither describes the project this sweep's population comes from.
    def repose_working_label(row)
      row.router.repose_working_label(row.issue, @client, clear_scope: true)
      doing = verifiable_working_label(row)
      return if doing.nil?

      carried = carried_labels(row)
      raise LabelNotPosed, "#{doing} is not on the ticket after the label write" unless carried.include?(doing)

      residue = handover(row.issue).scope_residue(carried, doing)
      return if residue.empty?

      raise LabelNotPosed, "#{residue.join(', ')} still sits beside #{doing} in autodev's scope"
    end

    def verifiable_working_label(row)
      config = project_config(row.issue.project_path)
      doing = config['label_doing'].to_s
      doing unless doing.empty? || !::Config.label_workflow?(config)
    end

    def carried_labels(row)
      Array(::GitlabHelpers.field(read_issue(row.issue), :labels))
    end

    # Built once per row, before any write, and used for both halves the router
    # owns: `repose_working_label` (the sweep's first write) and
    # `resume_never_reviewed` (its last). `reenter_via_pipeline_check` calls
    # `apply_label_doing` again on the way through; by then the ticket already
    # carries `label_doing`, `manage_labels` skips a write that would change
    # nothing, and no resource label event is emitted — which matters, because
    # those events are the record `LabelHandover` reads.
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
    # `hand_ticket_back` — so the strict rule declines 22 of the 23 rows it was
    # written to rescue. One is eligible today, which makes the pilot batch free.
    #
    # The permissive rule is therefore behind a flag, and it is narrow: the ticket
    # must be assigned to its author and to nobody else — exactly where
    # `hand_ticket_back` put it — with no human comment and no workflow-label
    # move by somebody else since `finished_at`. A permissive gesture is always a
    # written one.
    #
    # `human_comment_since?` raises on an unreadable thread (Autodev #67), so an
    # outage declines nothing into a verdict. `LabelHandover#moved_since?` keeps
    # that class's own rule instead — an unreadable event list reads as "nobody
    # moved it" — which is worth knowing when running with the flag on.
    # Why a row is or is not ours, not merely whether — because the report says it
    # out loud, and "assigned to user X, left untouched" on a row declined because
    # somebody commented on the ticket since the give-up names the wrong reason
    # (review of the alpha-52 lot). Each answer costs what it costs exactly once:
    # the reads happen here, and `ownership` only puts the verdict into words.
    def ownership_verdict(issue, gl_issue)
      return :externally_closed if externally_closed?(gl_issue)
      return :ours if assigned_to_autodev?(gl_issue)
      return :not_widened unless widened_to?(issue, gl_issue)
      return :touched_since unless untouched_since_giveup?(issue, gl_issue)

      :ours
    end

    # Which rows *beyond* the ones autodev still holds this run was told to
    # consider. Three tiers, each a superset of the one above it, and each written
    # by the operator rather than inferred:
    #
    #   * nothing — `assigned_to_autodev?` verbatim, one row of the 23;
    #   * `include_author_handback:` — the ticket went back to its author, and the
    #     author is who autodev's own `abandon_issue` handed it to, so the gesture
    #     that put it there is autodev's and not a human's;
    #   * `include_human_held:` — the ticket is held by ONE person, whoever they
    #     are. This is the tier the arrears need (Autodev #98): 4 of the 20 rows
    #     are held by somebody who is not the author, so the tier above declines
    #     them, and on GitLab Community autodev cannot join a ticket anyway — it
    #     takes it. What makes that acceptable is not the tier but what `reclaim`
    #     does with it: it says so on the ticket and it gives it back.
    #
    # A ticket held by NOBODY is deliberately in no tier: `dispatch_new_issues`
    # filters on assignment, so an unassigned ticket is one nobody is waiting on,
    # and the sweep's population is requests a human asked for.
    def widened_to?(issue, gl_issue)
      return assignee_ids(gl_issue).one? if @include_human_held

      @include_author_handback && handed_back_to_author?(issue, gl_issue)
    end

    # The protection that survives every tier, and the reason a username list is
    # not needed on top of it: what makes a row safe to re-arm is that NOBODY has
    # touched it since autodev gave it up. A person actively working the ticket
    # fails one of the three.
    #
    # The **merge request** is the third, and it was missing (Autodev #98). The
    # other two ask the ticket — its comments, its workflow label — and reviewing
    # the merge request is the gesture a reviewer actually makes. While the strict
    # filter only took rows already assigned to autodev that gap cost nothing;
    # widening to human-held rows is what makes it matter, so it is closed in the
    # same ticket that opens the filter.
    # The body moved to `Autodev::UntouchedSinceGiveup` when the alpha-53
    # neutral review found `PollRouter#resume_recovered_infra` re-arming — and
    # taking the ticket — without asking it. Two callers re-deriving one
    # protection is how it drifts, so there is one implementation and the
    # sweep reads it like everybody else.
    def untouched_since_giveup?(issue, gl_issue)
      UntouchedSinceGiveup.new(client: @client, logger: @logger,
                               project_config: ->(path) { project_config(path) })
                          .call(issue, gl_issue)
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

    # A GitLab mention is `@handle`; `@42` names nobody. Missing usernames are
    # simply absent from the map and the notice falls back to the id, because a
    # message that cannot name its reader is still owed to them.
    def usernames_of(gl_issue)
      Array(::GitlabHelpers.field(gl_issue, :assignees)).filter_map do |assignee|
        handle = handle_of(assignee)
        [::GitlabHelpers.field(assignee, :id), handle] if handle
      end.to_h
    end

    # Deliberately NOT `GitlabHelpers.field`: it falls back to `obj['username']`
    # for an object that does not answer the reader, and a Struct answers that
    # with a `NameError` — which `examine`'s boundary would report as a row that
    # could not be read. A handle is cosmetic (the notice falls back to the id),
    # so its absence must never cost a row its re-arm.
    def handle_of(assignee)
      assignee.username if assignee.respond_to?(:username)
    end

    def ownership(gl_issue, verdict)
      case verdict
      when :externally_closed then 'the ticket is closed on GitLab, left untouched'
      when :touched_since
        'somebody has touched the ticket or its merge request since the give-up, left untouched'
      else not_widened(assignee_ids(gl_issue))
      end
    end

    # Only reached for `:not_widened`, so every sentence here is about ownership
    # and nothing else.
    def not_widened(ids)
      return 'nobody is assigned on GitLab, left untouched' if ids.empty?
      return "assigned to users #{ids.join(', ')}, left untouched" unless ids.one?

      "assigned to user #{ids.first}, left untouched#{'; INCLUDE_HUMAN_HELD=1 would take it over' unless
        @include_human_held}"
    end

    # Has **this sweep** already re-armed this request? Read from `activity_events`
    # rather than from a new column: a `transition` row is never purged
    # (`transition` is not in `ActivityEvent::MACHINERY_KINDS`), so the record is
    # already there — and, since Autodev #88's review round, it carries the
    # *origin* of the transition and not only its event name, so the marker is
    # written by the very write it attests to and there is no second write to fail
    # on its own.
    #
    # Without it, a request re-armed and then given up again comes back into the
    # population with `review_count` still at 0, and the sweep re-arms it every
    # other run forever.
    #
    # Note the two things it is NOT.
    #
    # Not a comparison against `finished_at`: `Reviewer#give_up_reviewing`
    # rewrites `finished_at` to the moment of the *second* abandon, which is by
    # construction later than the re-arm being looked for, so the comparison would
    # answer "never re-armed" on exactly the rows it exists to catch.
    #
    # And not the bare presence of a `reenter_to_check_pipeline` event, which is
    # what shipped first. That event has three writers — a human reposing the todo
    # label, `PollRouter#resume_recovered_infra`, and this sweep — so its presence
    # says "this row went through a reentry once", not "this sweep re-armed it".
    # Measured on the 01/09/2026 production copy: 7 of the 23 rows carry one
    # already, dated June or July 2026, months BEFORE the August `finished_at`
    # being corrected — 30% of the target population silently discarded at every
    # run and for ever, under a counter (`already_swept`) that nothing
    # distinguishes from a true skip. Before Autodev #85 those rows were out of
    # the population anyway, because `resume_recovered_infra` wrote
    # `review_count: 1`; #85 stopped overwriting the 0 and made the false positive
    # reachable.
    def swept_before?(issue)
      ::ActivityEvent.where(issue_id: issue.id, kind: 'transition')
                     .where('payload_json LIKE ? ESCAPE ?', sweep_marker, '\\')
                     .exists?
    end

    # Derived from the value the router writes, never spelled out twice. `_` is a
    # LIKE wildcard, hence the escaping.
    def sweep_marker
      @sweep_marker ||= "%#{%("origin":"#{::PollRouter::REVIEW_ARREARS_ORIGIN}").gsub('_') { '\_' }}%"
    end

    def read_mr(issue)
      ::GitlabHelpers.answer(:merge_request) do
        @client.merge_request(issue.project_path, issue.mr_iid)
      end
    end

    # The merge request's facts travel to the operator and none of them is a
    # filter — the conflicts included, and that is a decision rather than an
    # omission (Matthieu, 01/09/2026).
    #
    # 12 of the 23 merge requests are in conflict, and the first row a default run
    # touches is one of them. Resolving a conflict is part of autodev's work:
    # `RepoRebaser#rebase_branch_on_target` rebases the branch onto its target
    # before every write action — the implementer's, `MrFixer`'s and
    # `PipelineFixer`'s alike — hands the conflicts to danger-claude when the
    # rebase stops, and force-pushes with a lease. That is what it does for any
    # merge request on any project, and there is nothing about these 23 that makes
    # it less true. Filtering them out would be asking this sweep to distrust the
    # correction path the requests are being sent back into.
    #
    # What follows is worth stating plainly rather than leaving to be discovered:
    # the batch is drained oldest-first, so the very first request re-armed is
    # also the one most likely to reach a danger-claude conflict resolution and a
    # force-push on a client branch. The review itself only reads; the force-push
    # comes at the correction round after it, and `LIMIT` (3, ceiling 10) is what
    # bounds how many of those can be in flight at once.
    #
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
          "mr closed #{tally[:mr_closed]}, conflicted #{tally[:mr_conflicted]}, " \
          "unknown state #{tally[:unknown_state]}, " \
          "already swept #{tally[:already_swept]}, not ours #{tally[:not_ours]}, " \
          "unreadable #{tally[:unreadable]}, incomplete #{tally[:incomplete]}")
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

    # The ticket does not carry `label_doing` after the write that was supposed to
    # pose it. Nested rather than filed under `lib/autodev/errors/` because it
    # never leaves this class: `rearm` catches it, reports the re-arm as
    # incomplete, and the row waits for a human.
    class LabelNotPosed < ::AutodevError; end

    # Autodev is not among the assignees after the write that was supposed to put
    # it there. Nested for `LabelNotPosed`'s reason, and raised for the same one:
    # on GitLab Community the assignment write is the one that can be accepted and
    # ignored, so an exception is not what its failure looks like either
    # (Autodev #98).
    class AssignmentNotLanded < ::AutodevError; end

    # `PollRouter` and `LabelHandover` log through the poller's logger; a rake run
    # has none and its report is the `out` stream.
    class NullLogger
      %i[info warn error debug].each { |level| define_method(level) { |_msg, **_opts| nil } }
    end
  end
end

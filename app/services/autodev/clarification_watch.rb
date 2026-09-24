# frozen_string_literal: true

module Autodev
  # The owner of a request parked in `needs_clarification` (Autodev #86).
  #
  # `dispatch_new_issues` is the state's only other reader, and it only sees the
  # tickets still assigned to autodev and still carrying a todo label, and only
  # ever resumes. Three cases had nobody: the ticket reassigned to a human (or
  # its entry label moved), the budget spent, and a question nobody answers.
  # Production row 68 sat in the first for 131 days. This pass signals all three
  # the same way — `needs_attention`, no GitLab comment, the row keeps waiting —
  # and closes the row only when the ticket was closed on GitLab.
  #
  # Flag and keep rather than close, for a reassigned row: re-entry from
  # `closed` needs a todo label posed *after* `finished_at`
  # (`LabelHandover#todo_reapplied_after?`), and a parked ticket already carries
  # one, so closing would turn the documented "reassign me" gesture into a
  # silent no-op. Row 68 resumed on 23/09/2026 because nothing had closed it.
  #
  # Not a `DormantAudit` arm: that pass closes or revives, "revive" means nothing
  # for a row waiting on a human, and adding the state to `STALLED_STATES` would
  # reach boot recovery, which would move every parked row to `pending`.
  class ClarificationWatch
    include ExternalState
    include ClarificationReach

    # Rank order, strongest first. A flag overwrites a weaker one, never a stronger one.
    #
    # A spent budget ranks first because it is the one case no GitLab gesture
    # moves: `PollDispatcher#process_issue` refuses the row on
    # `exceeded_retries?` before any reply is read, so a reach card shown over
    # it prescribed a reassignment that only swapped the card for this one a
    # cycle later (adversarial review of the alpha-55 lot).
    REASONS = %w[clarification_budget_spent clarification_reassigned
                 clarification_label_moved clarification_unanswered].freeze
    REACH_REASONS = %w[clarification_reassigned clarification_label_moved].freeze

    # The per-row boundary: the read's family, plus `StaleTransitionError`, the
    # closure refused on a row that moved meanwhile (Autodev #97). One row's
    # failure never stops the rest of the watch or the passes after it.
    ROW_ERRORS = [*READ_ERRORS, ::StaleTransitionError].freeze

    # rubocop:disable Metrics/ParameterLists -- DormantAudit's six plus
    # `seen_iids` / `listed_at`, the list this pass reads and the audit does not.
    #
    # `seen_iids`: the iids `dispatch_new_issues` received from GitLab this
    # cycle, or nil when that pass did not run (Claude gate closed) — then an
    # absence means nothing and the reach arm is skipped. `listed_at`: when that
    # list was fetched, taken before the fetch; a row parked after it cannot be
    # in it, so its absence is not evidence either.
    def initialize(client:, path:, config:, project_config:, logger:, seen_iids:, listed_at: nil,
                   now: Time.current)
      @client = client
      @path = path
      @config = config
      @project_config = project_config
      @logger = logger
      @seen_iids = seen_iids&.to_set(&:to_i)
      @listed_at = listed_at
      @now = now
    end
    # rubocop:enable Metrics/ParameterLists

    # Returns the number of rows whose flag changed (set or cleared) or that
    # were closed. Read after `dispatch_new_issues`, so a row resumed this
    # cycle is already `pending` and out of the population.
    def run
      ::Issue.where(project_path: @path, status: 'needs_clarification').to_a.sum { |issue| watch(issue) }
    end

    private

    # 1 when the row changed, 0 otherwise — the unit `run` sums.
    def watch(issue)
      reach = reach_verdict(issue)
      return close(issue) if reach == :closed

      settle(issue, target_reason(issue, reach))
    rescue *ROW_ERRORS => e
      @logger.error("Clarification watch on ##{issue.issue_iid} declined for this cycle: " \
                    "#{e.class}: #{e.message}", project: @path)
      0
    end

    # `close_externally`'s own return is whatever the activity post answered,
    # so the count is decided here.
    def close(issue)
      return 0 unless issue.may_close?

      close_externally(issue)
      1
    end

    # One reason per row. A fresh reach reading replaces a reach flag outright,
    # even with a weaker one — it is the ticket as it is now; budget and age
    # flags are cleared by a resume or an operator reset, and a foreign reason
    # (`dormant_exhausted`, left by a CLI `--reset`) only ever gives way to a
    # clarification reason — it ranks below all four.
    def target_reason(issue, reach)
      current = current_reason(issue)
      kept = reach != :unknown && REACH_REASONS.include?(current) ? nil : current
      fired = [(reach if REASONS.include?(reach)), budget_reason(issue), age_reason(issue)].compact
      strongest = fired.min_by { |reason| rank(reason) }
      strongest && rank(strongest) < rank(kept) ? strongest : kept
    end

    def current_reason(issue) = issue.needs_attention ? issue.attention_reason : nil

    # A foreign or absent reason ranks below every clarification reason.
    def rank(reason) = REASONS.index(reason) || REASONS.size

    # `>`, as `PollDispatcher#exceeded_retries?`: a row at the budget still has
    # one retry owed.
    def budget_reason(issue)
      'clarification_budget_spent' if issue.retry_count.to_i > max_retries
    end

    # A NULL `clarification_requested_at` reads as answered
    # (`ClarificationResume#answered?`), so there is nothing to age. The boundary
    # is `WatchBound#abandon_expired_watch`'s: the bound is reached on the day it
    # names.
    def age_reason(issue)
      asked = issue.clarification_requested_at
      return if max_days.zero? || asked.nil?

      'clarification_unanswered' if asked <= @now - max_days.days
    end

    # Written only when it changes the row, so a cycle where nothing changed
    # writes no flag and no activity entry that would feed
    # `Issue.without_activity_since` — the read's own stamp is the one write
    # such a cycle can make. A nil reason is a cleared reach flag.
    def settle(issue, reason)
      return 0 if reason == current_reason(issue)
      return lost_race(issue) unless write_matched?(issue, reason)

      if reason
        ::ActivityLogger.warn_event(issue, reason.to_sym, **activity_vars(issue, reason))
        @logger.warn("Issue ##{issue.issue_iid}: waiting for a clarification, flagged #{reason}", project: @path)
      else
        @logger.info("Issue ##{issue.issue_iid}: back in the todo list, reach flag cleared", project: @path)
      end
      1
    end

    # A compare-and-set on the state: a row a worker resumed between the select
    # and this write is not flagged. `attention_detail` is dropped with whatever
    # life wrote it — no clarification reason carries one.
    def write_matched?(issue, reason)
      ::Issue.where(id: issue.id, status: 'needs_clarification')
             .update_all(needs_attention: !reason.nil?, attention_reason: reason, attention_detail: nil)
             .positive?
    end

    def lost_race(issue)
      @logger.info("Issue ##{issue.issue_iid}: left needs_clarification during the watch, not flagged",
                   project: @path)
      0
    end

    # Missing one of these makes `warn_event` write nothing, silently: the
    # template's interpolation raises inside its own rescue.
    def activity_vars(issue, reason)
      case reason
      when 'clarification_budget_spent' then { count: issue.retry_count.to_i, max: max_retries }
      when 'clarification_unanswered' then { days: max_days }
      else {}
      end
    end

    def max_retries = @max_retries ||= ::Config.max_retries(@project_config, @config)

    def max_days = @max_days ||= ::Config.clarification_max_days(@project_config, @config)
  end
end

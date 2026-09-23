# frozen_string_literal: true

module Autodev
  # The reach arm of `ClarificationWatch` (Autodev #86): what GitLab says about
  # a parked row absent from the todo list, and when it is asked. Split out of
  # the watch when the adversarial review of the alpha-55 lot spaced the read
  # (`READ_INTERVAL`) and stopped a failed read from dropping the row; the
  # including class supplies `@client`, `@path`, `@logger`, `@project_config`,
  # `@seen_iids`, `@listed_at`, `@now`, and `ExternalState`'s two predicates.
  module ClarificationReach
    # How often a row absent from the list is read again. Every cycle cost 720
    # reads a day per row at production's `poll_interval: 120`, for as long as
    # the ticket stays out — and flag-and-keep means nobody has to close it. The
    # owner chose fifteen minutes on 23/09/2026: the delay a GitLab closure, or a
    # ticket changing how it is out of reach, takes to reach the card. The
    # gesture that resumes a row puts it back in the list, which costs no read.
    READ_INTERVAL = 15.minutes

    # The transport family is spelled out as `ExternalState#notify_stop` spells
    # it, for the reason given there. A read failing with one of these says
    # nothing about the reach, and the database arms still judge the row.
    READ_ERRORS = [::Gitlab::Error::ResponseError, ::ApiUnavailableError, ::SystemCallError,
                   ::Timeout::Error, ::SocketError, ::OpenSSL::SSL::SSLError, ::EOFError].freeze

    private

    # :reachable, :closed, a reach reason, or :unknown when nothing can be said.
    #
    # A row in the list is reachable by construction: the list is "open,
    # assigned to autodev, carrying a todo label". A row absent from it left
    # that population, and one read says how — at once on leaving, then every
    # `READ_INTERVAL` while it stays out, a reach flag included. Not re-reading
    # a flagged row at all (the first version) froze the flag on GitLab's first
    # answer: a ticket leaving in two steps kept the first step's explanation,
    # the gesture it prescribes changed nothing on the card, and a flagged
    # ticket closed on GitLab never closed the row (truthfulness and adversarial
    # reviews). The population that pays is the rows out of the list, 0 on
    # 23/09/2026, 96 reads a day each.
    def reach_verdict(issue)
      return :unknown if @seen_iids.nil? || parked_after_the_list?(issue)
      return back_in_the_list(issue) if @seen_iids.include?(issue.issue_iid.to_i)
      return :unknown if read_recently?(issue)

      read(issue)
    end

    # The stamp goes, so a row that leaves the list again is read at once.
    # Written only when there is one, so a healthy row still costs no write.
    def back_in_the_list(issue)
      ::Issue.where(id: issue.id).update_all(clarification_read_at: nil) if issue.clarification_read_at
      :reachable
    end

    # The bound is reached on the minute it names, as `age_reason`'s is on its day.
    def read_recently?(issue)
      read_at = issue.clarification_read_at
      !read_at.nil? && read_at > @now - READ_INTERVAL
    end

    # Stamped before the read, so a read that fails is spaced like one that
    # answers: a ticket GitLab answers 404 on costs one read and one error line
    # per interval, not per cycle. A failure is no verdict on the reach
    # (Autodev #62) and does not drop the row either: dropping it left a spent
    # budget and a months-old question unflagged for as long as the read kept
    # failing (adversarial review of the alpha-55 lot).
    def read(issue)
      ::Issue.where(id: issue.id).update_all(clarification_read_at: @now)
      read_reach(@client.issue(@path, issue.issue_iid))
    rescue *READ_ERRORS => e
      @logger.error("Clarification watch could not read ##{issue.issue_iid}, budget and age still judged: " \
                    "#{e.class}: #{e.message}", project: @path)
      :unknown
    end

    # `SpecChecker#post_clarification` parks the row (`spec_unclear!`, then the
    # stamp) before it reposes the entry label, so a row stamped after the list
    # was fetched is absent from it for that reason alone — and a read in that
    # window sees `label_doing` and flags `clarification_label_moved` falsely
    # (adversarial review). The next cycle's list settles it.
    def parked_after_the_list?(issue) = !@listed_at.nil? && issue.clarification_requested_at&.>=(@listed_at)

    # The explanation of `clarification_label_moved` does not claim a human
    # moved the label: `repose_entry_label` swallows its own failure, so autodev
    # itself can be the cause.
    def read_reach(gl_issue)
      return :closed if externally_closed?(gl_issue)
      return 'clarification_reassigned' unless assigned_to_autodev?(gl_issue)
      return 'clarification_label_moved' unless carries_todo_label?(gl_issue)

      :reachable
    end

    # Any value of `labels_todo` is an entry label, not only the first: both of
    # powerpanne's are in live use. A project with no todo label has no entry
    # label to lose, so the arm abstains rather than flag every row.
    def carries_todo_label?(gl_issue)
      todo = Array(@project_config['labels_todo'])
      return true if todo.empty?

      Array(::GitlabHelpers.field(gl_issue, :labels)).intersect?(todo)
    end
  end
end

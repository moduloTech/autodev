# frozen_string_literal: true

module Autodev
  # Puts autodev back in possession of a ticket a give-up handed to a human.
  #
  # `ReviewArrearsSweep#reclaim` (Autodev #88, corrected by #98) is the model:
  # write the assignment, **read it back** — our GitLab is Community edition,
  # one assignee per issue, and a write of a list GitLab cannot honour is
  # accepted (200) and silently ignored, so an unverified write is not a fact
  # — record who was displaced in `issues.displaced_assignee_id` (which is
  # what sends the eventual handback to them and not to the ticket's author,
  # `IssueNotifier#handback_target`), and announce the takeover by name.
  #
  # Autodev #93/#106 found two more passages that put a handed-back request
  # back to work without doing any of this: the infrastructure recheck
  # (`PollRouter#resume_recovered_infra`) and the operator reset (the
  # dashboard's *Réinitialiser* button and the `--reset` CLI, via
  # `Autodev::ResetReclaim`). This class is the model's *answer* — "does
  # autodev hold this ticket" — shared by both, so neither has to re-derive
  # it.
  #
  # Deliberately not folded into `ReviewArrearsSweep#reclaim` itself: that
  # method is entangled with the sweep's own `Row`/`landed`/`undo` reporting
  # (a rake's report has to say exactly what landed and what was undone), and
  # rebuilding it around this class would touch a path already exercised in
  # production for no behavioural gain. What moved into the shared body is
  # the model, not one implementation.
  #
  # The label half of the passage (design §3) is deliberately NOT this
  # class's concern — it stays with each caller, because whether
  # `clear_scope:` is safe differs by caller (only the sweep has asked
  # `untouched_since_giveup?` first).
  class TicketReclaim
    # Autodev is not among the assignees after the write that was supposed to
    # put it there. Raised rather than assumed, for the same reason as
    # `ReviewArrearsSweep::AssignmentNotLanded`: on GitLab Community the
    # assignment write is the one call that can be accepted and ignored.
    class AssignmentNotLanded < ::AutodevError; end

    # Bundles the GitLab comment's key + vars into one value, so the private
    # methods below that thread it through the write don't grow a parameter
    # list of their own — each caller passes its own reason (design §2).
    Notice = Struct.new(:key, :vars)

    def initialize(client:, logger: nil)
      @client = client
      @logger = logger
    end

    # Returns the assignee id list written (`[autodev]`), or `nil` when
    # autodev already held the ticket alone and nothing was written.
    #
    # `message_key:` names the GitLab comment posted when somebody is
    # displaced — each caller's own, because the reason autodev is taking the
    # ticket back differs (design §2): the sweep's names the revoked review
    # token, the infra recheck's names the recovered CI, the reset's names
    # the operator's own request. `message_vars` are interpolated alongside
    # the shared `tag:` / `user:` (both locales share the same placeholders).
    def reclaim!(issue, message_key:, **message_vars)
      autodev = ::GitlabHelpers.current_user_id(@client)
      gl_issue = read_issue(issue)
      before = assignee_ids(gl_issue)
      return nil if before == [autodev]

      write_assignment!(issue, autodev)
      record_takeover(issue, before, usernames_of(gl_issue), autodev, Notice.new(message_key, message_vars))
      [autodev]
    end

    private

    def write_assignment!(issue, autodev)
      @client.edit_issue(issue.project_path, issue.issue_iid, assignee_ids: [autodev])
      return if assignee_ids(read_issue(issue)).include?(autodev)

      raise AssignmentNotLanded, 'autodev is not among the assignees after the assignment write'
    end

    def read_issue(issue)
      ::GitlabHelpers.answer(:issue) { @client.issue(issue.project_path, issue.issue_iid) }
    end

    def assignee_ids(gl_issue)
      Array(::GitlabHelpers.field(gl_issue, :assignees)).map { |a| ::GitlabHelpers.field(a, :id) }
    end

    # A GitLab mention is `@handle`; `@42` names nobody. Missing usernames are
    # simply absent from the map and the notice falls back to the id — see
    # `ReviewArrearsSweep#usernames_of`, the same rule.
    def usernames_of(gl_issue)
      Array(::GitlabHelpers.field(gl_issue, :assignees)).filter_map do |assignee|
        handle = assignee.respond_to?(:username) ? assignee.username : nil
        [::GitlabHelpers.field(assignee, :id), handle] if handle
      end.to_h
    end

    # Written after the read-back, so nothing is recorded about a takeover
    # that did not happen. `displaced_assignee_id` stays untouched when
    # autodev displaced nobody (an unassigned ticket).
    def record_takeover(issue, before, usernames, autodev, notice)
      displaced = (before - [autodev]).first
      return unless displaced

      issue.update(displaced_assignee_id: displaced)
      announce(issue, usernames[displaced] || displaced, notice)
    end

    # The takeover itself has already landed and been read back; failing to
    # announce it must not undo it — reported instead, loudly.
    def announce(issue, username, notice)
      message = ::Locales.t(notice.key, locale: (issue.locale || 'fr').to_sym,
                                        tag: "**autodev** (v#{::Autodev::VERSION})",
                                        user: username, **notice.vars)
      @client.create_issue_note(issue.project_path, issue.issue_iid, message)
    rescue ::Gitlab::Error::ResponseError => e
      @logger&.error("Failed to announce the reclaim of ##{issue.issue_iid}: #{e.message}",
                     project: issue.project_path)
    end
  end
end

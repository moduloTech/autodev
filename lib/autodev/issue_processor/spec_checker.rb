# frozen_string_literal: true

require_relative 'prompts'
require_relative 'question_handler'

class IssueProcessor
  # Specification clarity check and question answering.
  module SpecChecker
    include QuestionHandler

    SPEC_HALT = :halt
    SPEC_CONTINUE = :continue

    private

    def check_specification(work_dir, context, iid, issue)
      log "Checking specification clarity for ##{iid}..."
      log_activity(issue, :spec_checking)
      out = with_context_file(work_dir, issue.branch_name, context) do |ctx|
        danger_claude_prompt(work_dir, format(Prompts::SPEC_CHECK, ctx), model: 'haiku')
      end
      parse_spec_result(out, iid, issue, work_dir, context)
    rescue JSON::ParserError
      log 'Could not parse spec check JSON, proceeding'
      issue.spec_clear!
      false
    end

    def parse_spec_result(out, iid, issue, work_dir, context)
      json_match = out.match(/\{[^{}]*"type"\s*:\s*"(implementation|question|unclear)"[^{}]*\}/m)
      return dispatch_spec_type(JSON.parse(json_match[0]), iid, issue, work_dir, context) if json_match

      legacy_spec_outcome(out, iid, issue) == SPEC_HALT
    end

    def dispatch_spec_type(result, iid, issue, work_dir, context)
      case result['type']
      when 'implementation'
        mark_spec_clear(issue)
        false
      when 'question'
        process_question(iid, issue, work_dir, context)
        true
      when 'unclear'
        resolve_unclear_spec(result['issues'], iid, issue) == SPEC_HALT
      end
    end

    def mark_spec_clear(issue)
      log 'Specification is clear, proceeding'
      issue.spec_clear!
      log_activity(issue, :spec_clear)
      nil
    end

    def process_question(iid, issue, work_dir, context)
      log "Issue ##{iid} is a question/investigation"
      issue.question_detected!
      log_activity(issue, :question_detected)
      answer_question(work_dir, context, iid, issue)
      nil
    end

    def resolve_unclear_spec(issues_list, iid, issue)
      issues_list = Array(issues_list).compact
      if issues_list.empty?
        log 'Spec unclear but no issues listed, proceeding'
        issue.spec_clear!
        return SPEC_CONTINUE
      end

      post_clarification(issues_list, iid, issue)
      SPEC_HALT
    end

    def legacy_spec_outcome(out, iid, issue)
      json_match = out.match(/\{[^{}]*"clear"\s*:\s*(true|false)[^{}]*\}/m)
      unless json_match
        log 'Could not parse spec check response, proceeding'
        issue.spec_clear!
        return SPEC_CONTINUE
      end

      result = JSON.parse(json_match[0])
      return resolve_unclear_spec(result['issues'], iid, issue) unless result['clear']

      mark_spec_clear(issue)
      SPEC_CONTINUE
    end

    # Handing the request to a human, and saying so on the board (Autodev #75).
    #
    # `dispatch_new_issues` discovers by asking GitLab for the issues assigned to
    # autodev **and** carrying a `labels_todo` label. This used to leave the
    # ticket on `label_doing`, so the request left that population the moment the
    # question was asked and nothing ever re-read the answer — `Issue::PROCESSABLE_STATES`
    # fixed the step after this one, but a row nobody discovers is not routed at
    # all. `apply_label_todo` closes the other half.
    #
    # It is also the truthful label: while autodev waits, the ticket is in the
    # hands of the person who was asked. Showing it as work in progress is a lie
    # about the board, and it is that lie that let 12 requests sleep for up to
    # three months without autodev or the PM seeing them. The cost is accepted and
    # named: the ticket goes back to the entry column, which reads as "nothing has
    # been done" on work that has already been cloned and analysed.
    #
    # `apply_label_todo` puts back the entry label the request arrived with, not a
    # guess between the two live ones. Idempotent: `manage_labels` skips the write
    # when it would change nothing, so re-posting on every poll costs no resource
    # label event.
    def post_clarification(issues_list, iid, issue)
      notify_clarification_questions(issues_list, iid)
      issue.spec_unclear!
      Issue.where(id: issue.id).update_all(clarification_requested_at: Time.current)
      repose_entry_label(iid)
      log_activity(issue, :spec_unclear, count: issues_list.size)
    end

    # Every GitLab call in `post_clarification` swallows its own failure, and this
    # one has to as well (Autodev #75).
    #
    # `notify_issue` rescues, `ActivityLogger.post` rescues — "failures must never
    # break the state machine". `apply_label_todo` was the exception: it is the
    # first *raising* GitLab call after `spec_unclear!` has already parked the row,
    # and `manage_labels` only catches `Gitlab::Error::ResponseError`. A transport
    # failure the gem does not wrap (`Errno::ECONNRESET`, `Net::OpenTimeout`)
    # escaped to `IssueProcessor#process`'s `rescue StandardError` →
    # `handle_process_error`, where `safe_mark_failed!` does nothing at all
    # (`needs_clarification` is not a `mark_failed` source state, and
    # `whiny_transitions: false` makes that a silent no-op) while every side effect
    # ran anyway: `retry_count` incremented, `finished_at` and `next_retry_at`
    # stamped, and an error comment posted directly under the questions. The
    # Autodev #61 shape — a no-op transition whose consequences still fire — made
    # reachable by adding a write after the state change.
    #
    # What is lost by swallowing is a board column: the ticket stays on
    # `label_doing` and the request is invisible until the next question or the
    # `autodev:recheck_clarifications` sweep. That is the pre-#75 behaviour, and it
    # is strictly better than telling the requester their ticket failed.
    def repose_entry_label(iid)
      apply_label_todo(iid)
    rescue StandardError => e
      log_error "Issue ##{iid}: could not repose the entry label (#{e.class}: #{e.message}) — " \
                'the question stands, the ticket stays on the doing label'
    end

    def notify_clarification_questions(issues_list, iid)
      locale = issue_locale(iid)
      header = Locales.t(:spec_unclear_header, locale: locale, tag: autodev_tag)
      footer = Locales.t(:spec_unclear_footer, locale: locale, tag: autodev_tag)
      numbered = issues_list.map.with_index(1) { |iss, i| "#{i}. #{iss}" }.join("\n")
      notify_issue(iid, "#{header}\n\n#{numbered}\n\n#{footer}")
    end

    def issue_locale(iid)
      record = Issue.where(project_path: @project_path, issue_iid: iid).first
      (record&.locale || 'fr').to_sym
    end
  end
end

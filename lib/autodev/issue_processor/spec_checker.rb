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
        danger_claude_prompt(work_dir, format(Prompts::SPEC_CHECK, ctx))
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

    def post_clarification(issues_list, iid, issue)
      notify_clarification_questions(issues_list, iid)
      issue.spec_unclear!
      apply_label_todo(iid)
      Issue.where(id: issue.id).update(clarification_requested_at: Sequel.lit("datetime('now')"))
      log_activity(issue, :spec_unclear, count: issues_list.size)
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

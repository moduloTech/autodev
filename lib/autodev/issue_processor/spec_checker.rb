# frozen_string_literal: true

require_relative 'prompts'

class IssueProcessor
  # Specification clarity check and question answering.
  module SpecChecker
    private

    def check_specification(work_dir, context, iid, issue)
      log "Checking specification clarity for ##{iid}..."
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

      parse_legacy_spec(out, iid, issue)
    end

    def dispatch_spec_type(result, iid, issue, work_dir, context)
      case result['type']
      when 'implementation'
        log 'Specification is clear, proceeding'
        issue.spec_clear!
        false
      when 'question'
        log "Issue ##{iid} is a question/investigation"
        issue.question_detected!
        answer_question(work_dir, context, iid, issue)
        true
      when 'unclear'
        apply_unclear_result(result['issues'], iid, issue)
      end
    end

    def parse_legacy_spec(out, iid, issue)
      json_match = out.match(/\{[^{}]*"clear"\s*:\s*(true|false)[^{}]*\}/m)
      unless json_match
        log 'Could not parse spec check response, proceeding'
        issue.spec_clear!
        return false
      end

      result = JSON.parse(json_match[0])
      return apply_unclear_result(result['issues'], iid, issue) unless result['clear']

      log 'Specification is clear, proceeding'
      issue.spec_clear!
      false
    end

    def apply_unclear_result(issues_list, iid, issue)
      issues_list = Array(issues_list).compact
      if issues_list.empty?
        log 'Spec unclear but no issues listed, proceeding'
        issue.spec_clear!
        return false
      end

      post_clarification(issues_list, iid, issue)
      true
    end

    def post_clarification(issues_list, iid, issue)
      locale = issue_locale(iid)
      header = Locales.t(:spec_unclear_header, locale: locale, tag: autodev_tag)
      footer = Locales.t(:spec_unclear_footer, locale: locale, tag: autodev_tag)
      numbered = issues_list.map.with_index(1) { |iss, i| "#{i}. #{iss}" }.join("\n")
      notify_issue(iid, "#{header}\n\n#{numbered}\n\n#{footer}")
      issue.spec_unclear!
      apply_label_todo(iid)
      Issue.where(id: issue.id).update(clarification_requested_at: Sequel.lit("datetime('now')"))
    end

    def answer_question(work_dir, context, iid, issue)
      log "Investigating question for issue ##{iid}..."
      answer = with_context_file(work_dir, issue.branch_name, context) do |ctx|
        danger_claude_prompt(work_dir, format(Prompts::QUESTION_INVESTIGATION, ctx), label: '-p (question)')
      end
      post_answer(iid, issue, answer)
    end

    def post_answer(iid, issue, answer)
      locale = issue_locale(iid)
      header = Locales.t(:question_answered_header, locale: locale, tag: autodev_tag)
      footer = Locales.t(:question_answered_footer, locale: locale, tag: autodev_tag)
      notify_issue(iid, "#{header}\n\n#{answer.strip}\n\n---\n#{footer}")
      finalize_question(iid, issue)
    end

    def finalize_question(iid, issue)
      label_workflow? ? manage_labels(iid, remove: [@project_config['label_doing']], add: nil) : update_labels(iid)
      issue.question_answered!
      reassign_to_author(issue)
      Issue.where(id: issue.id).update(finished_at: Sequel.lit("datetime('now')"),
                                       dc_stdout: @dc_stdout, dc_stderr: @dc_stderr)
    end

    def issue_locale(iid)
      record = Issue.where(project_path: @project_path, issue_iid: iid).first
      (record&.locale || 'fr').to_sym
    end
  end
end

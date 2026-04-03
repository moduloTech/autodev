# frozen_string_literal: true

require_relative 'prompts'

class IssueProcessor
  # Handles question/investigation tickets that don't require code changes.
  module QuestionHandler
    private

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
  end
end

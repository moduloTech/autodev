# frozen_string_literal: true

require 'json'
require 'time'

class MrFixer
  # A functional divergence found in review becomes a question on the ticket
  # (Autodev #121).
  #
  # `MrFixer` had one answer to every unresolved thread — correct the code — so a
  # thread that is a *product* decision locked it into corrections that could not
  # conclude. Measured on powerpanne/core#14746 (MR !11409): the review opened
  # « Divergence fonctionnelle (à valider par le PO) » threads quoting the
  # requester's own answers, and rounds 3 to 6 produced nothing but code comments
  # ("UI différée en attente d'arbitrage PO") until an unrelated stagnation gave
  # the request up. Nobody on the product side ever knew.
  #
  # The review now marks such a finding (`ReviewContract` `category`, carried
  # into GitLab by `ReviewPublisher::FUNCTIONAL_MARKER`), and a round that finds
  # one it has not asked about asks instead of fixing: the question goes on the
  # ticket, addressed to the requester, and the row waits in
  # `needs_clarification` with the #75/#86 machinery — entry label reposed,
  # `ClarificationWatch`, `ClarificationResume`. The answer brings it back here,
  # on the same merge request (`Issue#resume_on_merge_request?`).
  #
  # Including classes must have `@client`, `@project_path`, `@project_config`,
  # and the `DangerClaudeRunner` methods.
  module FunctionalQuestion
    private

    def functional_discussion?(discussion)
      Array(discussion[:notes]).first&.body.to_s.include?(ReviewPublisher::FUNCTIONAL_MARKER)
    end

    # Either the round asks — and stops — or it loads the answers the asked
    # threads already have, for `functional_answer_section`.
    def functional_question_asked?(issue, discussions)
      unasked = unasked_functional(issue, discussions)
      unasked.any? ? ask_functional_question(issue, unasked) : load_functional_answers(issue, discussions)
      unasked.any?
    end

    def unasked_functional(issue, discussions)
      asked = functional_questions_of(issue)
      discussions.select { |discussion| functional_discussion?(discussion) && !asked.key?(discussion[:id]) }
    end

    # The round stops here, and that is the second half of the fix: no thread of
    # the round is corrected — the code threads wait for the answer too, because
    # the decision may change the very code they are about — and nothing is
    # counted. `fix_round`, `discussion_fix_round` and `stagnation_signatures` are
    # all written by `execute_fix_cycle`, which this round never reaches, so a
    # question can lead neither to `stagnation_discussions` nor to
    # `fix_rounds_exhausted` (owner).
    #
    # The order is what makes a parked row mean "the question was posted": the
    # note is a *raising* post, unlike `notify_issue`, so an outage aborts at
    # `MrFixer#fix`'s boundary with the row still in `fixing_discussions` and the
    # next cycle asks again. Only then are the columns assigned and the event
    # fired, so the status and what the wait needs are written by one `save!`.
    def ask_functional_question(issue, threads)
      gl_issue = GitlabHelpers.answer(:issue) { @client.issue(@project_path, issue.issue_iid) }
      body = functional_question_body(issue, threads, gl_issue)
      GitlabHelpers.answer(:issue_note) { @client.create_issue_note(@project_path, issue.issue_iid, body) }
      park_on_functional_question(issue, threads)
      repose_entry_label_for_question(issue.issue_iid)
      log_activity(issue, :functional_question_asked, count: threads.size)
      log "MR !#{issue.mr_iid}: #{threads.size} functional divergence(s) — question asked on " \
          "##{issue.issue_iid}, waiting for the requester"
    end

    def park_on_functional_question(issue, threads)
      now = Time.current
      asked = functional_questions_of(issue).merge(threads.to_h { |thread| [thread[:id], now.utc.iso8601] })
      issue.assign_attributes(functional_questions: JSON.generate(asked), clarification_requested_at: now,
                              clarification_resume_to: Issue::RESUME_TO_FIXING)
      issue.functional_question!
    end

    # The #75 rationale, unchanged: `dispatch_new_issues` discovers by assignee
    # **and** todo label, so the parked ticket has to carry the entry label for
    # its answer to be read at all. Swallowed for the reason
    # `SpecChecker#repose_entry_label` gives: the question stands, and a ticket
    # left on the doing label is strictly better than a failure announced under
    # a question that was asked.
    def repose_entry_label_for_question(iid)
      apply_label_todo(iid)
    rescue StandardError => e
      log_error "Issue ##{iid}: could not repose the entry label (#{e.class}: #{e.message}) — " \
                'the question stands, the ticket stays on the doing label'
    end

    # The first round after the answer. The wait lasted days, and the merge
    # request may have been merged or closed meanwhile — `fixing_discussions`
    # used to be entered only minutes after `PipelineMonitor` read its state. So
    # the state is read first, and anything but `opened` sends the row back to
    # the watch, whose MR-state branch decides (a merge is a delivery, a close a
    # give-up, `locked` a wait); the destination is kept for the round that will
    # follow if the merge request comes back. Otherwise the ticket goes back to
    # the doing label and the destination is spent. A todo label on an active
    # row is not a handover (`LabelHandover#doing_dropped?`), so the window
    # between the resume and this round closes nothing.
    #
    # Answers true when the round must stop here.
    def mr_ended_after_answer?(issue)
      return false unless issue.clarification_resume_to

      unless merge_request_open?(issue)
        hand_back_to_the_watch(issue)
        return true
      end

      repose_doing_label_after_answer(issue.issue_iid)
      issue.update(clarification_resume_to: nil)
      false
    end

    def merge_request_open?(issue)
      mr = GitlabHelpers.answer(:merge_request) { @client.merge_request(@project_path, issue.mr_iid) }
      GitlabHelpers.field(mr, :state).to_s == 'opened'
    end

    def hand_back_to_the_watch(issue)
      log "MR !#{issue.mr_iid} is no longer open after the requester answered — back to the pipeline watch"
      issue.mr_ended_while_waiting!
    end

    def repose_doing_label_after_answer(iid)
      apply_label_doing(iid)
    rescue StandardError => e
      log_error "Issue ##{iid}: could not repose the doing label (#{e.class}: #{e.message})"
    end

    # The human notes posted on the ticket after each answered thread was asked,
    # read once per round. Read through `GitlabHelpers.answer` like the rest of
    # the prompt context (Autodev #67): a prompt silently missing the decision
    # would read exactly like a decision nobody took.
    def load_functional_answers(issue, discussions)
      asked = functional_questions_of(issue)
      answered = discussions.select { |discussion| asked.key?(discussion[:id]) }
      @functional_answers = answered.empty? ? {} : read_functional_answers(issue, answered, asked)
    end

    def read_functional_answers(issue, answered, asked)
      notes = GitlabHelpers.answer(:issue_notes) do
        @client.issue_notes(@project_path, issue.issue_iid, per_page: 100).auto_paginate
      end
      answered.to_h do |discussion|
        since = Time.parse(asked[discussion[:id]])
        [discussion[:id], notes.select { |note| HumanActivity.human_note_after?(note, since) }]
      end
    end

    # Appended to the thread's context, so the fixer and the verifier both read
    # the decision the correction has to apply.
    def functional_answer_section(discussion)
      notes = Array((@functional_answers || {})[discussion[:id]])
      return '' if notes.empty?

      quoted = notes.map { |note| "#{note.author&.name || 'Inconnu'} :\n\n#{note.body}" }.join("\n\n---\n\n")
      "\n\n#### Réponses à la question produit\n\nCe point relevait d'une décision produit. autodev a posé " \
        'la question au demandeur sur le ticket ; voici les commentaires publiés sur le ticket depuis :' \
        "\n\n#{quoted}\n\nApplique la décision qu'ils expriment.\n"
    end

    def functional_question_body(issue, threads, gl_issue)
      locale = issue.locale.to_s.empty? ? :fr : issue.locale.to_sym
      vars = { tag: autodev_tag, mr_iid: issue.mr_iid, count: threads.size, mention: requester_mention(gl_issue) }
      gaps = threads.map.with_index(1) { |thread, i| "#{i}. #{functional_gap(thread)}" }.join("\n\n")
      [Locales.t(:functional_question_header, locale: locale, **vars), gaps,
       Locales.t(:functional_question_footer, locale: locale, **vars)].join("\n\n")
    end

    def requester_mention(gl_issue)
      username = GitlabHelpers.field(GitlabHelpers.field(gl_issue, :author), :username)
      username.to_s.empty? ? '' : "@#{username} "
    end

    # The finding as the review wrote it, without what autodev added to it.
    def functional_gap(thread)
      body = Array(thread[:notes]).first&.body.to_s
      body.sub(/\A#{Regexp.escape(ReviewPublisher::FUNCTIONAL_MARKER)}\n[^\n]*\n\n/, '').strip
    end

    def functional_questions_of(issue) = Issue.parse_functional_questions(issue.functional_questions)
  end
end

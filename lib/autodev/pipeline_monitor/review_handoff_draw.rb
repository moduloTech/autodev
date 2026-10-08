# frozen_string_literal: true

class PipelineMonitor
  # The reviewer half of `ReviewHandoff` (Autodev #90): whether to draw at all,
  # what the project's draw answered, and the GitLab users and labels its
  # usernames stand for. Nothing here writes.
  module ReviewHandoffDraw
    include ReviewHandoffVocabulary

    private

    # A reviewer already on the merge request — a previous delivery of the same
    # request, or a human — is kept: a re-delivery must not hand the review to
    # somebody else, and a human's choice is not autodev's to undo.
    def draw_reviewers(work_dir, command, vars, red, merge_request)
      return :kept if reviewer_present?(merge_request)
      return :not_declared if command.blank?

      result = run_handoff_script(work_dir, handoff_argv(command, vars, red: red))
      resolve_reviewers(drawn_usernames(result))
    rescue Stop => e
      e
    end

    def reviewer_present?(merge_request)
      Array(GitlabHelpers.field(merge_request, :reviewers)).any? ||
        current_labels(merge_request).any? { |label| label.start_with?(REVIEWER_PREFIX) }
    end

    def drawn_usernames(result)
      refuse_unusable_draw(result)
      drawn = result.json['drawn']
      return drawn.first(2) if drawn.is_a?(Array) && drawn.any? && drawn.all?(String)

      raise Stop.new(:review_handoff_no_reviewer_draw_failed, reason: "drawn #{drawn.inspect}")
    end

    # Exit 2 is `reviewer_draw`'s "absence check failed, no draw made": no
    # reviewer, never a guessed one — the skill forbids working around it.
    def refuse_unusable_draw(result)
      reason = script_reason(result)
      raise Stop.new(:review_handoff_no_reviewer_absences, reason: reason) if result.exit_code == DRAW_UNAVAILABLE_EXIT
      raise Stop.new(:review_handoff_no_reviewer_draw_failed, reason: reason) unless result.success?
      raise Stop, :review_handoff_no_reviewer_postponed if result.json['postponed'] == true
    end

    # The label humans write is the first name (`MR::Reviewer::Lucas`), and the
    # draw returns usernames: GitLab's `name` bridges the two. The label must
    # already exist — derived from data, a wrong derivation would mint one.
    def resolve_reviewers(usernames)
      existing = existing_reviewer_labels
      usernames.map do |username|
        user = GitlabHelpers.answer(:users) { Array(@client.users(username: username)).first }
        label = user && "#{REVIEWER_PREFIX}#{GitlabHelpers.field(user, :name).to_s.split.first}"
        raise Stop.new(:review_handoff_no_reviewer_unresolved, username: username) unless existing.include?(label)

        DrawnReviewer.new(username, GitlabHelpers.field(user, :id), label)
      end
    end

    def existing_reviewer_labels
      labels = GitlabHelpers.answer(:labels) { @client.labels(@project_path, search: REVIEWER_PREFIX, per_page: 100) }
      Array(labels).map { |label| GitlabHelpers.field(label, :name) }
    end
  end
end

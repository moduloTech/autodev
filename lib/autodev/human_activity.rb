# frozen_string_literal: true

require 'time'

# "Has a person touched this since <instant>?", asked of a ticket or of its merge
# request. Extracted from `GitlabHelpers` to reduce module length, the way
# `LabelManager` and `IssueNotifier` were extracted from `DangerClaudeRunner`.
#
# One question, two objects, and they are two different gestures. Commenting the
# ticket is asking autodev for something — it is what `ResumeHandler` reads to
# decide a reposed label means "re-implement" rather than "carry on". Reviewing
# the merge request is a person saying "I have this", and it is the gesture a
# reviewer actually makes.
#
# `ReviewArrearsSweep` is the caller that needs both (Autodev #98). It may take a
# ticket away from the person who holds it — on GitLab Community an issue has one
# assignee, so joining is not available and taking is the only move — and doing
# that to somebody who has just picked the work back up is the single outcome its
# ownership filter exists to prevent.
module HumanActivity
  module_function

  def human_comment_since?(client, project_path, issue_iid, since)
    return false unless since

    notes = GitlabHelpers.answer(:issue_notes) do
      client.issue_notes(project_path, issue_iid, per_page: 100).auto_paginate
    end
    any_human_note_after?(notes, since)
  end

  def human_mr_comment_since?(client, project_path, mr_iid, since)
    return false unless since && mr_iid

    notes = GitlabHelpers.answer(:mr_notes) do
      client.merge_request_notes(project_path, mr_iid, per_page: 100).auto_paginate
    end
    any_human_note_after?(notes, since)
  end

  def any_human_note_after?(notes, since)
    threshold = since.is_a?(Time) ? since : Time.parse(since.to_s)
    notes.any? { |note| human_note_after?(note, threshold) }
  end

  # A system note is GitLab talking, and a note carrying autodev's signature is
  # autodev talking. Every merge request of the arrears population carries several
  # of the second kind, so reading them as a human gesture would decline the whole
  # population.
  def human_note_after?(note, threshold)
    !note.system &&
      Time.parse(note.created_at.to_s) > threshold &&
      !note.body.to_s.include?('**autodev**')
  end
end

# frozen_string_literal: true

module Autodev
  # "Has anybody touched this request since autodev gave it up?" — the one
  # question that makes re-arming a handed-back row safe, extracted so that
  # every passage which re-arms one asks it, and asks the *same* one.
  #
  # It was `ReviewArrearsSweep#untouched_since_giveup?`, private, and the
  # sweep's own comment states why it is the protection that matters:
  #
  #   "The protection that survives every tier, and the reason a username
  #    list is not needed on top of it: what makes a row safe to re-arm is
  #    that NOBODY has touched it since autodev gave it up."
  #
  # The alpha-53 neutral review (G2) found `PollRouter#resume_recovered_infra`
  # re-arming — and, since Autodev #93/#106, **taking the ticket** — on a
  # population that never asks it: `fetch_infra_recheck_candidates` filters on
  # status, flag, reason, MR and clocks, and on nothing a human did. So a
  # person who took an abandoned ticket back, fixed the CI and watched the
  # pipeline go green would lose the assignment (GitLab Community: one
  # assignee) to a comment telling them their infrastructure had recovered.
  # That is a false statement on a client's ticket, which is the harm Autodev
  # #98 exists for.
  #
  # Three questions, because a person leaves three different traces and the
  # sweep learned the third one the hard way (Autodev #98): a comment on the
  # ticket, a comment on the merge request — reviewing the merge request is
  # the gesture a reviewer actually makes — and a move of the workflow label.
  # `finished_at` is the give-up instant on every path, since Autodev #60
  # routed all of them through `abandon_issue`.
  #
  # A read that could not be answered is not a "no" (Autodev #62): the three
  # helpers raise on an unreadable GitLab, and this class lets that escape to
  # the caller's own boundary rather than converting it into permission.
  class UntouchedSinceGiveup
    def initialize(client:, project_config:, logger: nil)
      @client = client
      @project_config = project_config
      @logger = logger
    end

    def call(issue, gl_issue)
      return false if ::GitlabHelpers.human_comment_since?(@client, issue.project_path,
                                                           issue.issue_iid, issue.finished_at)
      return false if ::GitlabHelpers.human_mr_comment_since?(@client, issue.project_path,
                                                              issue.mr_iid, issue.finished_at)

      !handover(issue).moved_since?(gl_issue, issue.issue_iid, issue.finished_at)
    end

    private

    def handover(issue)
      LabelHandover.new(client: @client, path: issue.project_path,
                        project_config: project_config_for(issue), logger: @logger)
    end

    # The sweep walks several projects in one run and resolves the config per
    # row; `PollRouter` is already scoped to one project and passes it in.
    def project_config_for(issue)
      return @project_config.call(issue.project_path) if @project_config.respond_to?(:call)

      @project_config
    end
  end
end

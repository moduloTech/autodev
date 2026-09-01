# frozen_string_literal: true

# The one definition of "which branch is this work targeting" (Autodev #91).
#
# It is the base an autodev branch is rebased onto, the base its diff is measured
# against, and the branch its merge request goes into — one question, asked at
# five places in the tree, and answered three different ways before this ticket:
#
#   * `@project_config['target_branch'] || default_branch(work_dir)` in
#     `RepoRebaser#rebase_branch_on_target`, `MrManager#create_merge_request`,
#     `GitOperations#verify_changes` and `CloneHelpers#build_clone_cmd`;
#   * `default_branch(work_dir)` **alone**, config ignored, in
#     `MrFixer::FixCycle#build_fix_env` — which feeds `DiscussionFormatter`, so a
#     review thread was quoted to danger-claude with a hunk computed against a
#     base that neither the merge request nor the configuration named;
#   * the target the merge request itself carries — read by nobody. The `mr`
#     object was in hand in `PipelineMonitor#poll_open_mr` and never travelled
#     any further.
#
# That is the shape Autodev #72 removed twice (`MrState`, then
# `SkillsInjector.skill_paths`): one question, several hand-written answers, free
# to diverge.
#
# ## Two questions, not one
#
# The configuration is not the wrong answer. Two questions had been confused:
#
#   1. **Where do this project's _new_ merge requests go?** A property of the
#      project. `target_branch` in its configuration answers it, and correctly.
#   2. **Where does _this_ merge request go?** A property of that merge request,
#      recorded on GitLab when it was created.
#
# They are equal at birth — `create_merge_request` writes the config's value into
# the MR — and they diverge the moment the configuration moves while merge
# requests are open. So: **a new merge request takes the configuration, an
# existing one takes the target it carries.**
#
# Measured (PowerPanne, config moved from `staging` to `master` on 25/08/2026):
# on 01/09, 83 open merge requests still targeted `staging`, 64 of them on an
# autodev branch, and `master` carried 49 commits `staging` did not have. A write
# action on any of those lines fetched `master`, found new commits, rebased the
# branch onto `origin/master` and force-pushed it — a rebase always needs force.
# GitLab kept diffing the merge request against `staging`, so it then displayed
# commits and files the work never touched and every discussion thread's position
# was anchored on the previous diff.
#
# ## What is shared, and what is not
#
# What is shared is the **answer to "what is the base"**, not the decision that
# follows it — the same division Autodev #72 wrote out for `MrState`'s four
# readers. The rebaser decides whether to rebase, `verify_changes` decides whether
# the implementation produced anything, the formatter decides which hunk to quote,
# `create_merge_request` decides what to send GitLab. Each keeps its own decision.
# What they may not disagree on is which branch they are all talking about.
#
# ## A read that failed is not a value
#
# `of_merge_request` goes through `GitlabHelpers.answer` (Autodev #62/#67): the
# target comes from GitLab, and a read GitLab could not answer must **not** fall
# back on the configuration. That silent fallback is precisely what would have
# hidden this defect for another six months — every caller would have kept
# rebasing onto the config's branch and calling it the merge request's. It raises
# instead, and the existing boundaries (`MrFixer#fix`, `PipelineMonitor#check`)
# end the unit of work with the row untouched.
#
# The only GitLab read here is the merge request's own, which matters for
# `Gitlab::Error::NotFound`: a `NotFound` on this endpoint means *the merge
# request* is gone, never that its target branch is. Whether the target branch
# still exists is established from git, in `RepoRebaser#ensure_base_available!`,
# after the explicit fetch — where the two cannot be conflated (Autodev #89 hit
# the same trap between `404 Commit Not Found` and `404 File Not Found`).
module TargetBranch
  module_function

  # The project's declared target, or `nil` when it declares none.
  #
  # `nil` is a real answer, not a failure: it means "whatever the repository's
  # default branch is", and only a caller holding a clone can resolve that. The
  # clone command wants it un-resolved (`git clone` with no `--branch` picks the
  # remote's HEAD itself), which is why this is a function of its own rather than
  # a private step of `for_new_merge_request`.
  def declared(project_config)
    value = (project_config || {})['target_branch'].to_s.strip
    value.empty? ? nil : value
  end

  # Question 1 — a merge request that does not exist yet. `repository_default` is
  # the answer to "and if the project declares nothing?", which the caller
  # resolves because it needs the work directory.
  def for_new_merge_request(project_config, repository_default)
    declared(project_config) || repository_default
  end

  # The repository's own default branch, read through the API rather than from a
  # clone — the same answer as `Resolver#default_branch`, for the callers that
  # have no work directory to read it in. One question, two mechanisms, and they
  # live together on purpose: split apart, they are free to disagree about what an
  # undeclared `target_branch` means.
  def repository_default(client, project_path)
    GitlabHelpers.answer(:project) { client.project(project_path).default_branch }
  end

  # Question 1 again, for a fleet scan: a pass that sweeps every project without
  # holding a clone or a merge request — `ReviewSkillSource`'s probe. No merge
  # request is in hand, so the configuration *is* the right answer, and the
  # repository is only asked when the project declares nothing (one request per
  # cycle saved on every project that does).
  def for_fleet_scan(client, project_config, project_path)
    declared(project_config) || repository_default(client, project_path)
  end

  # Question 2 — a merge request that exists. GitLab holds the answer; nothing
  # local may stand in for it.
  def of_merge_request(client, project_path, mr_iid)
    mr = GitlabHelpers.answer(:merge_request_target) { client.merge_request(project_path, mr_iid) }
    named = GitlabHelpers.field(mr, :target_branch).to_s.strip
    raise MissingTargetBranchError.new(named, 'the merge request names no target branch') if named.empty?

    named
  end

  # Both questions in one place, for the callers that may be in either case —
  # `RepoRebaser`, which rebases both a branch whose merge request is open and one
  # that has none yet, and `verify_changes`, which runs on a first implementation
  # and on a re-implementation alike. `mr_iid` nil means no merge request carries
  # this work; the block resolves the repository default, and is not called when
  # there is a merge request to ask.
  def resolve(mr_iid, client:, project_path:, project_config:)
    return of_merge_request(client, project_path, mr_iid) if mr_iid

    for_new_merge_request(project_config, yield)
  end

  # The mixin half of the answer, for the workflow classes: the collaborators a
  # module of pure functions cannot hold, and the one thing that needs a clone on
  # disk rather than an API call.
  #
  # Included by `DangerClaudeRunner`, so `IssueProcessor`, `MrFixer` and
  # `PipelineMonitor` all reach it. Expects @client, @project_path,
  # @project_config, plus ShellHelpers (run_cmd_status).
  module Resolver
    private

    # Where every caller asks the one question. `mr_iid` nil means no merge
    # request carries this work yet, which is the only case the configuration
    # answers.
    def target_branch_for(work_dir, mr_iid)
      TargetBranch.resolve(mr_iid, client: @client, project_path: @project_path,
                                   project_config: @project_config) { default_branch(work_dir) }
    end

    # The repository's own default branch, which is what an undeclared
    # `target_branch` means. Private to the answer on purpose (Autodev #91): read
    # on its own it is the third of the three answers this ticket removed — it was
    # `build_fix_env`'s, ignoring even the configuration.
    def default_branch(work_dir)
      out, _err, ok = run_cmd_status(%w[git symbolic-ref refs/remotes/origin/HEAD --short], chdir: work_dir)
      ok && !out.strip.empty? ? out.strip.sub('origin/', '') : 'main'
    end
  end
end

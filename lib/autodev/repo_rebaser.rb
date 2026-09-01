# frozen_string_literal: true

# Rebase an autodev branch onto its target branch (`origin/<target_branch>`) before
# starting any write action (implementing, fixing discussions, fixing pipeline).
# Without this, danger-claude operates against a stale tree: target may have
# evolved since the autodev branch was created, leading to merge conflicts at the
# eventual MR merge and to MrFixer / PipelineFixer wrestling with thread positions
# or test failures that wouldn't exist on a rebased branch.
#
# Mixin: expects @logger, plus ShellHelpers (run_cmd_status), RepoOperations
# (push_with_lease_fallback), TargetBranch::Resolver (target_branch_for, which is
# what the callers below hand in as `base:`), and DangerClaudeRunner
# (danger_claude_prompt, log, log_error) to be available on the including class.
module RepoRebaser
  private

  # `base` is asked for rather than worked out here (Autodev #91): this module
  # used to answer "which branch" itself, with
  # `@project_config['target_branch'] || default_branch(work_dir)`, which is the
  # right answer only while no merge request carries the branch. The one
  # definition is `TargetBranch`, reached through `target_branch_for`, and it is a
  # required keyword so that a new caller has to have asked.
  #
  # Outcome symbols: :no_op (already up to date), :rebased (rebase applied and
  # pushed), :failed (clean rebase impossible, branch left untouched).
  def rebase_branch_on_target(work_dir, branch, base:)
    fetch_target_with_history(work_dir, base)
    ensure_base_available!(work_dir, base)
    return :no_op unless target_has_new_commits?(work_dir, base)

    log "Rebasing #{branch} on origin/#{base}..."
    _, _, ok = run_cmd_status(['git', 'rebase', "origin/#{base}"], chdir: work_dir)
    return finalize_rebase(work_dir, branch) if ok

    resolve_conflicts_then_continue(work_dir, branch, base)
  end

  # There is no such thing as rebasing onto a base that is not there (Autodev
  # #91). Every git question below — `git log HEAD..origin/<base>`, `git rebase`,
  # and the hunk `DiscussionFormatter` quotes — answers *nothing found* when the
  # ref is missing, which is byte-for-byte what "already up to date" looks like:
  # before this check a merge request whose target branch had been deleted was
  # silently not rebased, and the fix ran on a tree measured against nothing.
  #
  # Checked here rather than by asking GitLab whether the branch exists, for two
  # reasons. It covers every way the base can fail to arrive — deleted upstream,
  # a fetch that did not complete, a configured branch that never existed — and it
  # keeps `Gitlab::Error::NotFound` unambiguous: the only GitLab read on this path
  # is the merge request's own, so a `NotFound` there means the merge request is
  # gone and cannot be mistaken for a missing branch (the trap Autodev #89
  # documented between `404 Commit Not Found` and `404 File Not Found`).
  def ensure_base_available!(work_dir, base)
    out, _err, ok = run_cmd_status(['git', 'rev-parse', '--verify', '--quiet',
                                    "refs/remotes/origin/#{base}"], chdir: work_dir)
    return if ok && !out.strip.empty?

    raise MissingTargetBranchError.new(base, 'not on the remote after an explicit fetch')
  end

  # `--deepen` only works on shallow repos. Probe first; on a full clone, do a
  # normal fetch. In both cases use an explicit refspec so the remote-tracking
  # branch `refs/remotes/origin/<target>` gets created — `git fetch origin <target>`
  # alone only writes FETCH_HEAD on clones made with `--branch <other>`.
  def fetch_target_with_history(work_dir, target)
    is_shallow, = run_cmd_status(%w[git rev-parse --is-shallow-repository], chdir: work_dir)
    refspec = "+refs/heads/#{target}:refs/remotes/origin/#{target}"
    cmd = if is_shallow.strip == 'true'
            ['git', 'fetch', '--deepen=500', 'origin', refspec]
          else
            ['git', 'fetch', 'origin', refspec]
          end
    run_cmd_status(cmd, chdir: work_dir)
  end

  # `git log HEAD..origin/<target>` lists commits on target not in HEAD.
  # Non-empty → target moved ahead since branch was last rebased.
  def target_has_new_commits?(work_dir, target)
    out, _, ok = run_cmd_status(['git', 'log', "HEAD..origin/#{target}", '--oneline'],
                                chdir: work_dir)
    ok && !out.empty?
  end

  def resolve_conflicts_then_continue(work_dir, branch, target)
    log 'Rebase produced conflicts, asking danger-claude to resolve...'
    danger_claude_prompt(work_dir, build_conflict_prompt(branch, target))
    continue_after_resolution(work_dir, branch)
  rescue RateLimitError
    # Rate-limit signals the worker to pause. Abort the rebase first so the
    # tree is clean if the worker resumes later on this work_dir.
    run_cmd_status(%w[git rebase --abort], chdir: work_dir)
    raise
  rescue StandardError => e
    log_error "Conflict-resolution prompt failed (#{e.class}: #{e.message}); aborting rebase"
    run_cmd_status(%w[git rebase --abort], chdir: work_dir)
    :failed
  end

  def continue_after_resolution(work_dir, branch)
    out, _, ok = run_cmd_status(
      %w[git rebase --continue],
      chdir: work_dir,
      env: { 'GIT_EDITOR' => 'true' } # auto-accept the existing commit message
    )
    ok ? finalize_rebase(work_dir, branch) : abort_rebase(work_dir, out)
  end

  def finalize_rebase(work_dir, branch)
    log "Rebase succeeded, force-pushing #{branch}..."
    push_with_lease_fallback(work_dir, branch)
    :rebased
  end

  # Leave the branch in its pre-rebase state. The downstream action (implement
  # / fix) will run on stale-but-clean ground rather than block on a bad rebase.
  def abort_rebase(work_dir, continue_output)
    log_error "Rebase --continue failed; aborting rebase. Output: #{continue_output[0, 300]}"
    run_cmd_status(%w[git rebase --abort], chdir: work_dir)
    :failed
  end

  def build_conflict_prompt(branch, target)
    "Le rebase de la branche `#{branch}` sur `origin/#{target}` a produit des conflits. " \
      'Liste les fichiers en conflit avec `git status`, ouvre chacun, et resous les conflits ' \
      "en preservant l'intention des deux cotes (la branche d'autodev ET la cible). " \
      'Une fois tous les conflits resolus, fais `git add <files>` pour chaque fichier resolu ' \
      "mais NE LANCE PAS `git commit` ni `git rebase --continue` -- je m'en charge ensuite."
  end
end

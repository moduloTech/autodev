# frozen_string_literal: true

require_relative 'clone_helpers'

class IssueProcessor
  # Git clone, branch, push, and verification helpers.
  module GitOperations
    include CloneHelpers

    private

    def clone_repo(work_dir)
      FileUtils.rm_rf(work_dir)
      clone_url = build_clone_url
      cmd = build_clone_cmd(clone_url, work_dir)

      depth = @project_config['clone_depth'] || 1
      log "Cloning #{@project_path} (depth: #{depth.positive? ? depth : 'full'})..."
      run_cmd(cmd)

      setup_sparse_checkout(work_dir)
    end

    def fetch_and_checkout(work_dir, branch)
      run_cmd(['git', 'fetch', 'origin', "+refs/heads/#{branch}:refs/remotes/origin/#{branch}"], chdir: work_dir)
      run_cmd(['git', 'checkout', '-b', branch, "origin/#{branch}"], chdir: work_dir)
    end

    def create_branch(work_dir, iid, title)
      slug = I18n.transliterate(title)
                 .downcase
                 .gsub(/[^a-z0-9\s-]/, '')
                 .gsub(/\s+/, '-')
                 .gsub(/-+/, '-')
                 .gsub(/^-|-$/, '')[0, 50]
      branch_name = "autodev/#{iid}-#{slug}-#{SecureRandom.hex(4)}"
      run_cmd(['git', 'checkout', '-b', branch_name], chdir: work_dir)
      log "Created branch: #{branch_name}"
      branch_name
    end

    def push(work_dir, branch_name)
      log "Pushing #{branch_name}..."
      push_with_lease_fallback(work_dir, branch_name, upstream: true)
    end

    # "Did the implementation produce anything?" is the same question as the
    # rebase's — commits on this branch that its base does not have — so it asks
    # the one definition too (Autodev #91). `mr_iid` is nil on a first
    # implementation and set on a re-implementation, where the branch's base is
    # the target its merge request carries.
    #
    # Against `origin/<base>` rather than a bare `<base>`: the local branch of the
    # base exists only when the clone happened to check it out, which is no longer
    # true once the base is the merge request's rather than the configuration's.
    #
    # The remote-tracking ref is there in the two nominal cases — from the clone on
    # a first implementation, and from `fetch_target_with_history` on a
    # re-implementation, which ran just before this in `resolve_branch` — and the
    # review round found the third case, where it is not (constat 2). The reuse
    # arm is the one that fetches; when the previous branch is gone from the remote
    # `resolve_branch` takes `create_branch` instead, which fetches nothing, and
    # the clone is `--depth 1 --branch <config>`, i.e. single-branch.
    #
    # So the two non-zero answers are separated instead of being merged into one
    # message. `git log A..B` exits non-zero both for "B has no commits A lacks"
    # (which it does not — it exits 0 with empty output) and for "A does not
    # resolve", and reading the second as the first announced an implementation
    # that produced nothing, on a request whose implementation was never measured:
    # `error`, a retry spent, and a message pointing the reader at danger-claude.
    # `ensure_base_available!` is the one definition of "is the base there", shared
    # with the rebaser, and it says which of the two happened.
    def verify_changes(work_dir, branch_name, mr_iid)
      base = target_branch_for(work_dir, mr_iid)
      out, _err, ok = run_cmd_status(['git', 'log', "origin/#{base}..#{branch_name}", '--oneline'],
                                     chdir: work_dir)
      ensure_base_available!(work_dir, base) unless ok
      raise ImplementationError, 'No changes produced by implementation' unless ok && !out.strip.empty?
    end

    # A read the caller acts on, so a failed one has no representation as data
    # (Autodev #62, review round of #91). This answered `false` for every
    # `ResponseError`, and `false` is the *decision* branch: `reuse` false sends
    # `resolve_branch` to `create_branch`, which cuts a fresh branch off the clone
    # and fetches no base — so a 502 on this endpoint threw away a branch that was
    # there and then measured the work against a ref the clone does not have.
    # Only the remote saying "no such branch" may answer `false`.
    def branch_exists_on_remote?(branch_name)
      GitlabHelpers.answer(:branch) do
        @client.branch(@project_path, branch_name)
        true
      rescue Gitlab::Error::NotFound
        false
      end
    end

    def clone_and_prepare(issue, iid, work_dir)
      previous_branch = issue.branch_name
      reuse = previous_branch && branch_exists_on_remote?(previous_branch)
      depth = @project_config['clone_depth'] || 1
      log_activity(issue, :cloning, detail: depth.positive? ? "depth: #{depth}" : 'full')
      clone_repo(work_dir)
      return recover_to_mr(issue, work_dir, previous_branch) if reuse && %w[creating_mr
                                                                            reviewing].include?(issue.status)

      branch = setup_branch(issue, work_dir, iid, previous_branch, reuse)
      run_implementation(issue, work_dir, iid, branch)
      branch
    end

    def recover_to_mr(issue, work_dir, branch)
      fetch_and_checkout(work_dir, branch)
      @current_branch_name = branch
      issue._skip_to_mr = true
      issue.clone_complete!
      branch
    end

    def setup_branch(issue, work_dir, iid, previous_branch, reuse)
      branch = resolve_branch(work_dir, iid, issue, previous_branch, reuse)
      issue.update(branch_name: branch)
      @current_branch_name = branch
      issue.clone_complete!
      branch
    end

    # The one caller of the rebaser that can be in either case (Autodev #91): the
    # branch is being reused, so a merge request may already carry it — a
    # re-implementation of a delivered ticket — or may not, when the previous run
    # stopped before `create_merge_request`. `issue.mr_iid` is the discriminator,
    # and it is the same one `verify_changes` reads a few steps later, so the two
    # cannot measure against different bases.
    def resolve_branch(work_dir, iid, issue, previous_branch, reuse)
      if reuse
        log "Reusing existing branch: #{previous_branch}"
        fetch_and_checkout(work_dir, previous_branch)
        rebase_branch_on_target(work_dir, previous_branch,
                                base: target_branch_for(work_dir, issue.mr_iid))
        previous_branch
      else
        create_branch(work_dir, iid, issue.issue_title)
      end
    end

    def ensure_claude_md(work_dir)
      claude_md = File.join(work_dir, 'CLAUDE.md')
      return if File.exist?(claude_md)

      log 'No CLAUDE.md found, generating...'
      danger_claude_prompt(
        work_dir,
        'Analyse ce projet (structure, technologies, conventions, tests) et cree un fichier CLAUDE.md ' \
        'a la racine qui documente ces informations pour guider les futurs developpements. ' \
        'Sois concis et factuel.'
      )
      danger_claude_commit(work_dir)
    end
  end
end

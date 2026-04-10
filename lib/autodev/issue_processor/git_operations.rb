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

    def verify_changes(work_dir, branch_name)
      target = @project_config['target_branch'] || default_branch(work_dir)
      out, _err, ok = run_cmd_status(['git', 'log', "#{target}..#{branch_name}", '--oneline'], chdir: work_dir)
      raise ImplementationError, 'No changes produced by implementation' unless ok && !out.strip.empty?
    end

    def branch_exists_on_remote?(branch_name)
      @client.branch(@project_path, branch_name)
      true
    rescue Gitlab::Error::ResponseError
      false
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

    def resolve_branch(work_dir, iid, issue, previous_branch, reuse)
      if reuse
        log "Reusing existing branch: #{previous_branch}"
        fetch_and_checkout(work_dir, previous_branch)
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

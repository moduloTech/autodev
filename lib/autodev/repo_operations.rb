# frozen_string_literal: true

# Clone-and-push helpers used by IssueProcessor, MrFixer, and PipelineMonitor.
# Mixin: expects @gitlab_url, @token, @project_path, @project_config, and a `log` helper.
module RepoOperations
  private

  def clone_and_checkout(work_dir, branch)
    FileUtils.rm_rf(work_dir)

    uri = URI.parse(@gitlab_url)
    host_port = uri.port && ![80, 443].include?(uri.port) ? "#{uri.host}:#{uri.port}" : uri.host
    clone_url = "#{uri.scheme}://oauth2:#{@token}@#{host_port}/#{@project_path}.git"

    clone_depth = @project_config['clone_depth'] || 1
    cmd = %w[git clone]
    cmd += ['--depth', clone_depth.to_s] if clone_depth.positive?
    cmd += ['--branch', branch]
    cmd += [clone_url, work_dir]

    run_cmd(cmd)
  end

  def default_branch(work_dir)
    out, _err, ok = run_cmd_status(%w[git symbolic-ref refs/remotes/origin/HEAD --short], chdir: work_dir)
    ok && !out.strip.empty? ? out.strip.sub('origin/', '') : 'main'
  end

  def push_with_lease_fallback(work_dir, branch, upstream: false)
    push_cmd = %w[git push]
    push_cmd << '-u' if upstream
    push_cmd += ['origin', branch]
    _out, _err, ok = run_cmd_status(push_cmd, chdir: work_dir)
    return if ok

    log 'Push failed, retrying with --force-with-lease...'
    force_cmd = ['git', 'push', '--force-with-lease']
    force_cmd << '-u' if upstream
    force_cmd += ['origin', branch]
    run_cmd(force_cmd, chdir: work_dir)
  end
end

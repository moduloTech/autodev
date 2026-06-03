# frozen_string_literal: true

# Clone-and-push helpers used by IssueProcessor, MrFixer, and PipelineMonitor.
# Mixin: expects @gitlab_url, @token, @project_path, @project_config, plus `log` and `log_error` helpers.
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
    log_push_diagnostics(work_dir)
    _out, _err, ok = run_cmd_status(push_cmd(branch, upstream: upstream), chdir: work_dir)
    return if ok

    log 'Push failed, retrying with --force-with-lease...'
    run_cmd(push_cmd(branch, upstream: upstream, force: true), chdir: work_dir)
  rescue GitError => e
    log_large_blobs(work_dir) if e.message.include?('pack exceeds maximum allowed size')
    raise
  end

  def push_cmd(branch, upstream:, force: false)
    cmd = %w[git push]
    cmd << '--force-with-lease' if force
    cmd << '-u' if upstream
    cmd += ['origin', branch]
    cmd
  end

  # Logs a snapshot of HEAD + pack stats so we can diagnose oversized pushes
  # after the work_dir has been cleaned up. Cheap (~50ms) so always-on.
  def log_push_diagnostics(work_dir)
    stat_out, = run_cmd_status(['git', 'log', '-1', '--stat', '--format=%h %s', 'HEAD'], chdir: work_dir)
    objs_out, = run_cmd_status(%w[git count-objects -vH], chdir: work_dir)
    log "Push diagnostics:\n#{stat_out}\n#{objs_out}"
  rescue StandardError => e
    log_error "log_push_diagnostics failed: #{e.message}"
  end

  # Top N blobs by on-disk size — surfaces the culprit when a push is rejected
  # for exceeding the server-side pack limit (e.g. a committed vendor/ directory).
  def log_large_blobs(work_dir, limit: 10)
    top = collect_top_blobs(work_dir, limit)
    formatted = top.map { |size, path| format('%<size>12d  %<path>s', size: size, path: path) }.join("\n")
    log "Top #{top.size} blobs by on-disk size:\n#{formatted}"
  rescue StandardError => e
    log_error "log_large_blobs failed: #{e.message}"
  end

  def collect_top_blobs(work_dir, limit)
    raw, waiters = Open3.pipeline_r(
      %w[git rev-list --objects --all],
      ['git', 'cat-file', '--batch-check=%(objecttype) %(objectsize:disk) %(rest)'],
      chdir: work_dir
    )
    blobs = raw.each_line.filter_map { |line| parse_blob_line(line) }
    raw.close
    waiters.each(&:join)
    blobs.sort_by { |size, _| -size }.first(limit)
  end

  def parse_blob_line(line)
    type, size, *rest = line.strip.split(' ', 3)
    return unless type == 'blob' && size

    [size.to_i, rest.join(' ')]
  end
end

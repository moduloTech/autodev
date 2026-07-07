# frozen_string_literal: true

# Clone-and-push helpers used by IssueProcessor, MrFixer, and PipelineMonitor.
# Mixin: expects @gitlab_url, @token, @project_path, @project_config, plus `log` and `log_error` helpers.
module RepoOperations
  # GitLab rejects a push whose received pack exceeds this (its `receive.maxInputSize`,
  # 50 MiB by default). We size the objects a push would send *before* sending them,
  # so an oversized commit fails fast with an actionable message naming the culprit
  # files, instead of an opaque "pack exceeds maximum allowed size" from the server
  # after a wasted round-trip (and its --force-with-lease retry).
  MAX_PUSH_PACK_BYTES = 50 * 1024 * 1024

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
    check_push_size!(work_dir)
    log_push_diagnostics(work_dir)
    _out, _err, ok = run_cmd_status(push_cmd(branch, upstream: upstream), chdir: work_dir)
    return if ok

    log 'Push failed, retrying with --force-with-lease...'
    run_cmd(push_cmd(branch, upstream: upstream, force: true, lease: remote_lease(work_dir, branch)),
            chdir: work_dir)
  rescue GitError => e
    log_large_blobs(work_dir) if e.message.include?('pack exceeds maximum allowed size')
    raise
  end

  # The remote value we fetched for the branch (refs/remotes/origin/<branch>),
  # used as the explicit force-with-lease expectation. nil when no remote-tracking
  # ref exists (a brand-new branch) — the bare lease is then fine.
  def remote_lease(work_dir, branch)
    out, _err, ok = run_cmd_status(['git', 'rev-parse', '--verify', '--quiet', "refs/remotes/origin/#{branch}"],
                                   chdir: work_dir)
    ok && !out.strip.empty? ? out.strip : nil
  end

  # Objects reachable from HEAD but not from any remote-tracking ref are exactly
  # what a push would upload — for the initial push (new branch) and for an MR
  # re-push alike (already-pushed commits are excluded via origin/<branch>). If
  # their on-disk (compressed) size clears GitLab's pack limit, abort now.
  def check_push_size!(work_dir)
    objs = push_object_sizes(work_dir)
    total = objs.sum { |size, _| size }
    return if total <= MAX_PUSH_PACK_BYTES

    top = objs.sort_by { |size, _| -size }.first(10)
    raise ImplementationError, oversized_push_message(total, top)
  end

  # Sizes of the objects a push would upload. Isolated so a probe failure returns
  # [] (push proceeds) — the rescue must NOT wrap the ImplementationError raise in
  # check_push_size!, or it would swallow the very abort it is meant to trigger.
  def push_object_sizes(work_dir)
    collect_objects(work_dir, %w[HEAD --not --remotes])
  rescue StandardError => e
    log_error "check_push_size! probe skipped: #{e.message}"
    []
  end

  def oversized_push_message(total, top)
    listing = top.map { |size, path| format('%<mib>8.1f MiB  %<path>s', mib: size / 1_048_576.0, path: path) }
                 .join("\n")
    format(
      'Push aborted: this commit adds %<total>.1f MiB of new objects, over GitLab\'s %<limit>d MiB pack ' \
      'limit. This is almost always a build artifact, dump or vendored dependency committed by mistake — ' \
      "add it to .gitignore and drop it from the commit. Largest new files:\n%<listing>s",
      total: total / 1_048_576.0, limit: MAX_PUSH_PACK_BYTES / 1_048_576, listing: listing
    )
  end

  def push_cmd(branch, upstream:, force: false, lease: nil)
    cmd = %w[git push]
    cmd << force_lease_flag(branch, lease) if force
    cmd << '-u' if upstream
    cmd += ['origin', branch]
    cmd
  end

  # An explicit-value lease (--force-with-lease=<branch>:<sha>) keeps the
  # anti-clobber guarantee (the push is refused if the remote moved past <sha>
  # since we fetched) WITHOUT triggering the implicit --force-if-includes that a
  # bare --force-with-lease carries since git 2.30. After re-implementing an
  # existing branch we rebase it on the advanced target, rewriting history so the
  # previously-delivered remote commit is no longer an ancestor; the includes
  # check then rejects the push with "stale info" (task #33). This is aggravated
  # by the `clone_depth: 1` clone (--single-branch), where origin/<branch> exists
  # only via the one-off fetch. Falls back to the bare form when we have no
  # leased sha.
  def force_lease_flag(branch, lease)
    lease ? "--force-with-lease=#{branch}:#{lease}" : '--force-with-lease'
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

  # Top N blobs by on-disk size across the whole repo — the safety-net that still
  # surfaces the culprit when a push slips past check_push_size! and the server
  # rejects it (e.g. a committed vendor/ directory).
  def log_large_blobs(work_dir, limit: 10)
    top = collect_objects(work_dir, %w[--all]).sort_by { |size, _| -size }.first(limit)
    formatted = top.map { |size, path| format('%<size>12d  %<path>s', size: size, path: path) }.join("\n")
    log "Top #{top.size} blobs by on-disk size:\n#{formatted}"
  rescue StandardError => e
    log_error "log_large_blobs failed: #{e.message}"
  end

  # [[on_disk_size, path], ...] for every blob reachable from the given rev-list
  # revs (e.g. %w[--all] for the whole repo, %w[HEAD --not --remotes] for a push).
  def collect_objects(work_dir, revs)
    raw, waiters = Open3.pipeline_r(
      %w[git rev-list --objects] + revs,
      ['git', 'cat-file', '--batch-check=%(objecttype) %(objectsize:disk) %(rest)'],
      chdir: work_dir
    )
    blobs = raw.each_line.filter_map { |line| parse_blob_line(line) }
    raw.close
    waiters.each(&:join)
    blobs
  end

  def parse_blob_line(line)
    type, size, *rest = line.strip.split(' ', 3)
    return unless type == 'blob' && size

    [size.to_i, rest.join(' ')]
  end
end

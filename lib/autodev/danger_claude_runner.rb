# frozen_string_literal: true

# Shared module for IssueProcessor, MrFixer, and PipelineMonitor.
# Provides danger-claude execution, git clone, timeout handling,
# issue notification, and logging.
#
# Including classes must call `init_runner(...)` in their initialize.

# Env hash that explicitly unsets all Bundler-related vars in child processes.
CLEAN_ENV = %w[
  BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_BIN_PATH BUNDLE_APP_CONFIG
  BUNDLE_ORIG_GEMFILE BUNDLER_VERSION BUNDLER_ORIG_BUNDLER_VERSION
  BUNDLER_SETUP RUBYOPT RUBYLIB
].each_with_object({}) { |var, h| h[var] = nil }.freeze

module DangerClaudeRunner
  include ShellHelpers

  private

  def init_runner(client:, config:, project_config:, logger:, token:)
    @client         = client
    @config         = config
    @project_config = project_config
    @logger         = logger
    @token          = token
    @project_path   = project_config["path"]
    @gitlab_url     = config["gitlab_url"]
    @dc_stdout      = +""
    @dc_stderr      = +""
  end

  RATE_LIMIT_PATTERN = /you've hit your limit|rate limit|usage limit/i
  RATE_LIMIT_RESET_PATTERN = /resets?\s+(\d{1,2})(am|pm)\s*\(UTC\)/i

  def danger_claude_prompt(work_dir, prompt, label: "-p", agent: nil)
    args = ["-p", prompt]
    if agent
      args.unshift("-a", agent)
      @logger.debug("danger-claude -a #{agent} -p prompt:\n#{prompt}", project: @project_path)
    else
      @logger.debug("danger-claude -p prompt:\n#{prompt}", project: @project_path)
    end
    out, err, ok = run_with_timeout("danger-claude", args, chdir: work_dir, label: label)
    unless ok
      check_rate_limit!(out, err)
      raise ImplementationError, "danger-claude -p failed:\nstdout: #{out[0, 500]}\nstderr: #{err[0, 500]}"
    end
    check_rate_limit!(out, err)
    out
  end

  def danger_claude_commit(work_dir, label: "-c")
    out, err, ok = run_with_timeout("danger-claude", ["-c"], chdir: work_dir, label: label)
    unless ok
      check_rate_limit!(out, err)
      raise ImplementationError, "danger-claude -c failed:\nstdout: #{out[0, 500]}\nstderr: #{err[0, 500]}"
    end
    out
  end

  def check_rate_limit!(stdout, stderr)
    combined = "#{stdout}\n#{stderr}"
    return unless combined.match?(RATE_LIMIT_PATTERN)

    reset_time = parse_reset_time(combined)
    raise RateLimitError.new("API rate limit reached#{reset_time ? " (resets #{reset_time.strftime("%H:%M UTC")})" : ""}", reset_time: reset_time)
  end

  def parse_reset_time(text)
    match = text.match(RATE_LIMIT_RESET_PATTERN)
    return nil unless match

    hour = match[1].to_i
    ampm = match[2].downcase
    hour += 12 if ampm == "pm" && hour != 12
    hour = 0 if ampm == "am" && hour == 12

    now = Time.now.utc
    reset = Time.utc(now.year, now.month, now.day, hour, 0, 0)
    reset += 86_400 if reset <= now # next day if already past
    reset
  end

  def clone_and_checkout(work_dir, branch)
    FileUtils.rm_rf(work_dir) if Dir.exist?(work_dir)

    uri = URI.parse(@gitlab_url)
    host_port = uri.port && ![80, 443].include?(uri.port) ? "#{uri.host}:#{uri.port}" : uri.host
    clone_url = "#{uri.scheme}://oauth2:#{@token}@#{host_port}/#{@project_path}.git"

    clone_depth = @project_config["clone_depth"] || 1
    cmd = ["git", "clone"]
    cmd += ["--depth", clone_depth.to_s] if clone_depth.positive?
    cmd += ["--branch", branch]
    cmd += [clone_url, work_dir]

    run_cmd(cmd)
  end

  def run_with_timeout(cmd, args, chdir:, label: nil)
    timeout = (@project_config["dc_timeout"] || @config["dc_timeout"] || 1800).to_i
    tag = label ? "#{cmd} #{label}" : cmd

    stdout_r, stdout_w = IO.pipe
    stderr_r, stderr_w = IO.pipe

    pid = Process.spawn(CLEAN_ENV, cmd, *args, chdir: chdir, in: :close, out: stdout_w, err: stderr_w)
    stdout_w.close
    stderr_w.close

    out_thread = Thread.new { stdout_r.read }
    err_thread = Thread.new { stderr_r.read }

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      if remaining <= 0
        Process.kill("TERM", pid)
        sleep 5
        Process.kill("KILL", pid) rescue nil
        Process.wait(pid) rescue nil
        out = out_thread.value
        err = err_thread.value
        @dc_stdout << "=== #{tag} (TIMEOUT after #{timeout}s) ===\n#{out}\n"
        @dc_stderr << "=== #{tag} (TIMEOUT after #{timeout}s) ===\n#{err}\n"
        raise ImplementationError, "#{tag} timed out after #{timeout}s"
      end

      _pid, status = Process.wait2(pid, Process::WNOHANG)
      if status
        out = out_thread.value
        err = err_thread.value
        @dc_stdout << "=== #{tag} ===\n#{out}\n"
        @dc_stderr << "=== #{tag} ===\n#{err}\n"
        raise Interrupt, "#{tag} interrupted by signal" if status.signaled? && status.termsig == Signal.list["INT"]
        return [out, err, status.success?]
      end

      sleep 1
    end
  ensure
    stdout_r&.close
    stderr_r&.close
  end

  def notify_issue(iid, message)
    @client.create_issue_note(@project_path, iid, message)
  rescue Gitlab::Error::ResponseError => e
    log_error "Failed to post comment on ##{iid}: #{e.message}"
  end

  def log(msg)
    @logger.info(msg, project: @project_path)
  end

  def log_error(msg)
    @logger.error(msg, project: @project_path)
  end
end

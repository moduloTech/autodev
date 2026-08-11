# frozen_string_literal: true

# Extracted from DangerClaudeRunner to reduce module length.
# Provides process spawning, timeout handling, and output capture
# for long-running subprocesses.
#
# Including classes must have @dc_stdout, @dc_stderr, and CLEAN_ENV accessible.
module ProcessRunner
  private

  # `timeout:` overrides the danger-claude cap for a caller that runs a different
  # program (Autodev #54: mr-review has its own, measured profile). Left nil, the
  # resolution is unchanged for the two danger-claude entry points.
  def run_with_timeout(cmd, args, chdir:, label: nil, timeout: nil)
    timeout = resolve_timeout(timeout)
    tag = label ? "#{cmd} #{label}" : cmd
    pid, stdout_r, stderr_r = spawn_process(cmd, args, chdir)
    PortAllocator.release(@port_mappings) if @port_mappings
    out_thread = Thread.new { stdout_r.read }
    err_thread = Thread.new { stderr_r.read }
    wait_for_completion(pid, tag, timeout, out_thread, err_thread)
  ensure
    stdout_r&.close
    stderr_r&.close
  end

  # Extracted from run_with_timeout to keep its cyclomatic complexity under the
  # RuboCop threshold once the `timeout:` kwarg added a fourth fallback term.
  def resolve_timeout(timeout)
    (timeout || @project_config['dc_timeout'] || @config['dc_timeout'] || 600).to_i
  end

  def spawn_process(cmd, args, chdir)
    stdout_r, stdout_w = IO.pipe
    stderr_r, stderr_w = IO.pipe
    pid = Process.spawn(
      DangerClaudeRunner::CLEAN_ENV, cmd, *args,
      chdir: chdir, in: :close, out: stdout_w, err: stderr_w, pgroup: true
    )
    stdout_w.close
    stderr_w.close
    [pid, stdout_r, stderr_r]
  end

  def wait_for_completion(pid, tag, timeout, out_thread, err_thread)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    loop do
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      handle_timeout(pid, tag, timeout, out_thread, err_thread) if remaining <= 0

      status = check_process_status(pid)
      return finish_process(status, tag, out_thread, err_thread) if status

      sleep 1
    end
  end

  def handle_timeout(pid, tag, timeout, out_thread, err_thread)
    kill_process_group(pid)
    record_output(tag, "TIMEOUT after #{timeout}s", out_thread, err_thread)
    raise ImplementationError, "#{tag} timed out after #{timeout}s"
  end

  def kill_process_group(pid)
    Process.kill('TERM', -pid)
    sleep 5
    safe_kill(pid)
    safe_wait(pid)
  end

  def safe_kill(pid)
    Process.kill('KILL', -pid)
  rescue StandardError
    nil
  end

  def safe_wait(pid)
    Process.wait(pid)
  rescue StandardError
    nil
  end

  def check_process_status(pid)
    _pid, status = Process.wait2(pid, Process::WNOHANG)
    status
  end

  def finish_process(status, tag, out_thread, err_thread)
    out, err = record_output(tag, nil, out_thread, err_thread)
    raise Interrupt, "#{tag} interrupted by signal" if status.signaled? && status.termsig == Signal.list['INT']

    [out, err, status.success?]
  end

  def record_output(tag, suffix, out_thread, err_thread)
    out = out_thread.value
    err = err_thread.value
    header = suffix ? "#{tag} (#{suffix})" : tag
    @dc_stdout << "=== #{header} ===\n#{out}\n"
    @dc_stderr << "=== #{header} ===\n#{err}\n"
    [out, err]
  end
end

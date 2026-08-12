# frozen_string_literal: true

require_relative 'redactor'

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

  # The Process::Status is returned as a fourth, optional element (Autodev #49).
  # `status.success?` alone cannot tell "the program ran and refused" (exit 1)
  # from "there was no program to run" (exit 127) from "it was killed before it
  # could say anything" (a termsig) — and on the failure shape that ticket is
  # about, where both streams come back empty, that distinction is the entire
  # diagnostic. Surplus on a three-variable destructuring, so the two
  # danger-claude callers are unaffected.
  def finish_process(status, tag, out_thread, err_thread)
    out, err = record_output(tag, nil, out_thread, err_thread)
    raise Interrupt, "#{tag} interrupted by signal" if status.signaled? && status.termsig == Signal.list['INT']

    [out, err, status.success?, status]
  end

  # The two buffers are a durable, human-facing sink: eleven error/give-up paths
  # across the four workers copy them into `issues.dc_stdout` /
  # `issues.dc_stderr`, the CLI `--errors` prints stderr back, and the issue
  # detail page renders both. So they get the same treatment as every other such
  # sink and are scrubbed on the way in (Autodev #59).
  #
  # Here rather than at the persistence sites: this is the only writer of the two
  # ivars, so one scrub covers every current site and every future one — #49
  # scrubbed the log message it built from these streams but persisted the
  # columns raw, and the eleven older sites never scrubbed at all.
  #
  # The caller's copy is deliberately left alone: `capture_session_and_text`
  # JSON-parses stdout and RateLimitDetector / AuthFailureDetector match fatal
  # signatures in it, so rewriting it would change how danger-claude output is
  # read rather than where a secret can be read back.
  def record_output(tag, suffix, out_thread, err_thread)
    out = out_thread.value
    err = err_thread.value
    header = suffix ? "#{tag} (#{suffix})" : tag
    @dc_stdout << Redactor.scrub("=== #{header} ===\n#{out}\n")
    @dc_stderr << Redactor.scrub("=== #{header} ===\n#{err}\n")
    [out, err]
  end
end

# frozen_string_literal: true

require 'timeout'

# The bounded, stdin-writing spawn behind UsageChecker#verdict.
#
# Extracted from UsageChecker into its own module purely to keep the class
# under RuboCop's line budget — this is UsageChecker's private plumbing, not a
# second shared primitive next to ProcessRunner. Reproducing
# ProcessRunner#kill_process_group's TERM-then-KILL sequence here instead of
# reusing it is deliberate (Autodev #108 design §3): that method depends on
# @dc_stdout / @project_config / @port_mappings, none of which a usage probe
# has any business owning, and it spawns with `in: :close` where this probe
# must write to the child's stdin. Extracting one shared bounded-spawn
# primitive for both is a real, tempting refactor and is explicitly out of
# scope for this ticket.
#
# Including classes must set @command, @timeout and @kill_grace (see
# UsageChecker#initialize).
module UsageProbeSpawn
  POLL_INTERVAL = 0.2 # seconds between liveness checks while waiting on the probe

  private

  # A trio of pipes for a single spawn — extracted so `send_probe` reads as the
  # three things it does (spawn, hand off stdin, wait) rather than plumbing.
  Pipes = Struct.new(:stdin_r, :stdin_w, :stdout_r, :stdout_w, :stderr_r, :stderr_w) do
    def self.open
      new(*IO.pipe, *IO.pipe, *IO.pipe)
    end

    def close_child_ends
      stdin_r.close
      stdout_w.close
      stderr_w.close
    end

    def close_all
      each { |io| io.close unless io.closed? }
    end
  end
  private_constant :Pipes

  def send_probe
    pipes = Pipes.open
    pid = spawn_probe(pipes)
    pipes.close_child_ends
    write_stdin(pipes.stdin_w)
    out_thread = Thread.new { pipes.stdout_r.read }
    err_thread = Thread.new { pipes.stderr_r.read }
    wait_probe(pid, out_thread, err_thread)
  ensure
    pipes&.close_all
  end

  def spawn_probe(pipes)
    Process.spawn(DangerClaudeRunner::CLEAN_ENV, *@command,
                  in: pipes.stdin_r, out: pipes.stdout_w, err: pipes.stderr_w, pgroup: true)
  end

  def write_stdin(stdin_w)
    stdin_w.write('.')
    stdin_w.close
  end

  def wait_probe(pid, out_thread, err_thread)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @timeout
    loop do
      status = wait_pid(pid)
      return [out_thread.value, err_thread.value, status] if status
      raise Timeout::Error, 'danger-claude probe timed out' if past?(deadline)

      sleep POLL_INTERVAL
    end
  rescue Timeout::Error
    kill_process_group(pid)
    raise
  end

  def past?(deadline) = Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

  def wait_pid(pid)
    _pid, status = Process.wait2(pid, Process::WNOHANG)
    status
  end

  def kill_process_group(pid)
    Process.kill('TERM', -pid)
    sleep @kill_grace
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
end

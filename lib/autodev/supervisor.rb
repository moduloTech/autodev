# frozen_string_literal: true

module Autodev
  # Step 6 of the railsification (cf. autodev/docs/autospec.md §D phase C):
  # `bin/autodev` becomes a supervisor that boots `rails server` + the Solid
  # Queue worker (`bin/jobs`) as child processes, instead of running the
  # poll loop in-process. The parent owns signal handling and lifecycle —
  # if any child dies it tears the whole thing down so systemd / launchd /
  # the operator can restart cleanly.
  class Supervisor # rubocop:disable Metrics/ClassLength
    TERM_GRACE_SECONDS = 10

    # Per-child handle. `command` and `env` are passed to `Process.spawn`
    # verbatim; `pid` is filled in after the spawn call.
    Child = Struct.new(:name, :command, :env, :pid) do
      def alive?
        return false unless pid

        Process.kill(0, pid)
        true
      rescue Errno::ESRCH, Errno::EPERM
        false
      end
    end

    def initialize(children:, logger:, spawner: nil, sleeper: nil)
      @children = children
      @logger = logger
      @shutdown = false
      # Injection seams for tests — defaults route to real OS calls.
      @spawner = spawner || method(:default_spawn)
      @sleeper = sleeper || method(:sleep)
    end

    # Autodev #92: any abrupt end of this method — an exception out of
    # spawn_all after the first child, an exception out of wait_loop, a
    # signal the trap does not cover — must still take every already-spawned
    # child with it. `shutdown_children` is idempotent (send_term skips a
    # child that is not alive?, force_kill_stragglers rescues ESRCH/ECHILD),
    # so running it here on the normal path too — instead of as `run`'s last
    # statement — is harmless, and it is the only shape that also covers a
    # partial spawn_all: it tears down exactly the children that exist.
    def run
      trap_signals
      spawn_all
      wait_loop
    ensure
      shutdown_children
    end

    private

    def trap_signals
      %w[INT TERM].each do |sig|
        Signal.trap(sig) do
          # Trap context can't safely call logger.* (which may take a mutex
          # held elsewhere in the main thread). Just flip the flag and let
          # the main loop log and react.
          @shutdown = true
        end
      end
    end

    def spawn_all
      @children.each do |child|
        child.pid = @spawner.call(child.env, child.command)
        @logger.info("[supervisor] spawned #{child.name} (pid=#{child.pid})")
      end
    end

    def wait_loop
      until @shutdown
        @sleeper.call(0.5)
        reap_once
      end
    end

    def reap_once
      pid, status = Process.wait2(-1, Process::WNOHANG)
    rescue Errno::ECHILD
      # No more children, nothing left to supervise.
      @shutdown = true
    else
      return unless pid

      handle_child_exit(pid, status)
    end

    # A non-zero exit is a crash → tear everything down (launchd restarts). A
    # clean exit (status 0) leaves the surviving children running: tearing
    # down on every orderly stop just churns restarts, each stranding the
    # worker's in-flight Solid Queue jobs as pruned "failed" executions.
    def handle_child_exit(pid, status)
      child = @children.find { |c| c.pid == pid }
      label = child&.name || "pid=#{pid}"
      child&.pid = nil
      if status.exitstatus&.zero?
        return @logger.info("[supervisor] child #{label} exited cleanly (status=0); peers kept")
      end

      @logger.error("[supervisor] child #{label} exited (status=#{status.exitstatus.inspect}); shutting down peers")
      @shutdown = true
    end

    # `Autodev::ProcessStopper` (Autodev #109) has the same shape for a *foreign*
    # pid. This one is not written in terms of it: `send_term` logs per child,
    # and `force_kill_stragglers` must `Process.wait` — these are our children
    # and we owe them a reap, where the boot guard's orphans belong to init.
    # `ProcessStopper#alive?` is `Process.kill(0, pid)`, which cannot tell a
    # running process from a zombie: pointed at our own child it would read a
    # killed-but-unreaped process as alive until something reaps it — measured
    # by adopting the module and watching it happen against a real
    # ignore-SIGTERM subprocess, not assumed.
    #
    # `ProcessStopper.stop` is also per-pid, where this method waits for every
    # child against one shared deadline; adopting it would make two
    # simultaneous stragglers wait out `TERM_GRACE_SECONDS` one after another
    # instead of together — measured at ~20s against today's ~10s. The
    # production LaunchAgent plist on bobette declares no `ExitTimeOut`, so
    # launchd SIGKILLs a job that has not stopped after its **20-second
    # default** — the doubled worst case would sit exactly on that budget
    # instead of comfortably inside it, and a supervisor SIGKILLed mid-teardown
    # leaves behind every child it had not reached yet, which is the orphan
    # `Autodev::BootGuard` (Autodev #92, #109) exists to clean up after.
    #
    # Two escalations on purpose, not by accident; the grace is asserted equal
    # in test/process_stopper_test.rb.
    def shutdown_children
      send_term
      wait_for_graceful_exit
      force_kill_stragglers
    end

    def send_term
      @children.each do |child|
        next unless child.alive?

        @logger.info("[supervisor] stopping #{child.name} (pid=#{child.pid})")
        Process.kill('TERM', child.pid)
      rescue Errno::ESRCH
        # Already gone.
      end
    end

    def wait_for_graceful_exit
      deadline = monotonic_now + TERM_GRACE_SECONDS
      until @children.none?(&:alive?) || monotonic_now >= deadline
        reap_pending
        @sleeper.call(0.2)
      end
    end

    def reap_pending
      loop do
        pid, = Process.wait2(-1, Process::WNOHANG)
        break unless pid

        @children.each { |c| c.pid = nil if c.pid == pid }
      end
    rescue Errno::ECHILD
      # Nothing left.
    end

    def force_kill_stragglers
      @children.select(&:alive?).each do |child|
        @logger.warn("[supervisor] force-killing #{child.name} (pid=#{child.pid}) after #{TERM_GRACE_SECONDS}s grace")
        Process.kill('KILL', child.pid)
        Process.wait(child.pid)
      rescue Errno::ESRCH, Errno::ECHILD
        # Already reaped.
      end
    end

    def default_spawn(env, command)
      Process.spawn(env, *command)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

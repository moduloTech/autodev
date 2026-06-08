# frozen_string_literal: true

module Autodev
  # Step 6 of the railsification (cf. autodev/docs/autospec.md §D phase C):
  # `bin/autodev` becomes a supervisor that boots `rails server` + the Solid
  # Queue worker (`bin/jobs`) as child processes, instead of running the
  # poll loop in-process. The parent owns signal handling and lifecycle —
  # if any child dies it tears the whole thing down so systemd / launchd /
  # the operator can restart cleanly.
  class Supervisor
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

    def run
      trap_signals
      spawn_all
      wait_loop
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

      crashed = @children.find { |c| c.pid == pid }
      label = crashed&.name || "pid=#{pid}"
      @logger.error("[supervisor] child #{label} exited (status=#{status.exitstatus.inspect}); shutting down peers")
      crashed&.pid = nil
      @shutdown = true
    end

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

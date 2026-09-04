# frozen_string_literal: true

module Autodev
  # Autodev #109. Stop a process and *observe* that it stopped.
  #
  # `BootGuard#reap` used to send one TERM and log "Stopping it (TERM)". At the
  # alpha-53 deployment (03/09/2026 17h18) the alpha-52 puma survived that TERM
  # and stayed alive for forty minutes, holding `autodev.db`, its WAL and its
  # shared-memory file open for writing on three descriptors. A manual KILL was
  # needed; `PRAGMA wal_checkpoint(PASSIVE)` answered `0|322|322` immediately
  # afterwards, which is the checkpoint the ghost had been blocking.
  #
  # == Why this is not `Supervisor#shutdown_children`
  #
  # The supervisor has the same shape — TERM, bounded wait, KILL — but it works
  # on **its own children**: `force_kill_stragglers` ends in `Process.wait`,
  # which raises `ECHILD` on a foreign pid. A boot guard's orphan belongs to
  # pid 1; init reaps it, and trying to reap it here would be an error. So the
  # shape is shared and the code is not. There is deliberately no `Process.wait`
  # anywhere in this file.
  #
  # Liveness is `Process.kill(0, pid)`, the same probe `Supervisor::Child#alive?`
  # (`lib/autodev/supervisor.rb`) makes — but the two read `EPERM` differently,
  # deliberately. `Supervisor::Child#alive?` rescues `ESRCH` and `EPERM` together
  # and answers `false` for both, which is correct for *its* question ("is this
  # one of my own children still running", and a pid this process cannot signal
  # was never spawned by it). This module answers a different question, "is
  # this pid still on the process table at all", where `EPERM` is proof the pid
  # exists and belongs to somebody else — reading it as gone would let `stop`
  # declare victory over a process it never touched.
  module ProcessStopper
    # The same value as `Supervisor::TERM_GRACE_SECONDS`, declared here rather
    # than read from there: a module operating on a bare pid must not depend on
    # the supervisor, and that dependency would have to be undone if the
    # supervisor ever adopts this module. `test/process_stopper_test.rb` asserts
    # the two stay equal.
    DEFAULT_GRACE_SECONDS = 10

    # SIGKILL cannot be caught, so this is a confirmation window and not a
    # grace: it covers the microseconds between the signal and the process
    # leaving the table, not any work the process might do.
    KILL_CONFIRM_SECONDS = 2

    POLL_INTERVAL_SECONDS = 0.2

    module_function

    # Returns one of :gone_on_term, :gone_on_kill, :alive — always a statement
    # about what was observed, never about what was requested.
    def stop(pid, grace: DEFAULT_GRACE_SECONDS, overrides: {})
      seams = resolve_seams(overrides)

      return :gone_on_term unless seams[:killer].call('TERM', pid)
      return :gone_on_term if gone_within?(pid, grace, seams)
      return :gone_on_kill unless seams[:killer].call('KILL', pid)
      return :gone_on_kill if gone_within?(pid, KILL_CONFIRM_SECONDS, seams)

      :alive
    end

    # Extracted out of `stop` on its own: with the four fallbacks resolved
    # inline, `stop` tripped RuboCop's Cyclomatic/PerceivedComplexity cops
    # (9 against thresholds of 7/8) — the same shape as the two rulings this
    # module was built under, one gate this module's own first draft did not
    # pass either.
    def resolve_seams(overrides)
      { alive: overrides[:alive] || method(:alive?),
        killer: overrides[:killer] || method(:signal),
        sleeper: overrides[:sleeper] || method(:sleep),
        clock: overrides[:clock] || method(:monotonic_now) }
    end

    def gone_within?(pid, seconds, seams)
      deadline = seams[:clock].call + seconds
      loop do
        return true unless seams[:alive].call(pid)
        return false if seams[:clock].call >= deadline

        seams[:sleeper].call(POLL_INTERVAL_SECONDS)
      end
    end

    def alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    # `false` means "already gone", which is the outcome we wanted rather than
    # an error: a process that died between two instructions is stopped.
    def signal(sig, pid)
      Process.kill(sig, pid)
      true
    rescue Errno::ESRCH
      false
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

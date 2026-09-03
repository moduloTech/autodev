# frozen_string_literal: true

require 'open3'

module Autodev
  # Autodev #92 design §2: a signal the supervisor's trap does not cover
  # (SIGKILL) leaves nothing to run, so nothing inside `Supervisor#run` can
  # help. `KeepAlive: Crashed` in the LaunchAgent plist means launchd
  # restarts the supervisor when its main process dies without stopping the
  # process group, so a child already spawned by the dead supervisor keeps
  # running, reparented to pid 1, holding the SQLite file (+ WAL/SHM) open
  # for writing — the ghost this ticket is named for.
  #
  # `Supervisor#run`'s own `ensure` (see supervisor.rb) closes this gap going
  # forward, for every abrupt end this *process* can still react to. This
  # class closes it for the one case that process cannot reach at all: an
  # orphan that already exists, belonging to a *different*, already-dead
  # supervisor, discovered when a fresh one boots.
  #
  # Runs once, before `Supervisor#spawn_all`. Scoped narrowly on purpose —
  # only a process both (a) holding our database file open and (b)
  # reparented to pid 1 is even considered a candidate:
  #
  #   * recognised as one of ours (its command matches the rails-server or
  #     solid-queue child) → it is a child of a previous supervisor; log and
  #     terminate it, then let the new boot proceed;
  #   * anything else — an unrecognised command, or a recognised command that
  #     is *not* reparented to pid 1 (so it may belong to a still-running
  #     sibling supervisor rather than a dead one) — refuse to start and name
  #     what was found. A blanket refusal on every restart would be a boot
  #     loop under `KeepAlive: Crashed`, worse than the leak it replaces, so
  #     only the case autodev cannot positively identify and safely reap
  #     stops the boot.
  #
  # No holder at all is a silent pass — the common case, costing one lsof +
  # zero ps calls, and worth staying quiet about.
  class BootGuard
    # One recognised holder, as reported by `ps -o ppid=,command=`.
    Holder = Struct.new(:pid, :ppid, :command)

    # Matched against the *live* process title, not the argv autodev spawned
    # it with — Puma renames its own `$0` once it has bound the port (the
    # production ghost measured on 01/09 showed `puma 6.6.1 (tcp://…)`, not
    # `bin/rails server …`), and Solid Queue's fork supervisor does the same
    # (`solid-queue-fork-supervisor: supervising …`). The `bin/rails …
    # server` / `bin/jobs … start` alternatives cover a very freshly spawned
    # orphan that has not renamed itself yet.
    RECOGNIZED_COMMANDS = {
      'rails-server' => %r{(bin/rails\b.*\bserver\b)|(^puma\b)},
      'solid-queue' => %r{solid[_-]queue|(bin/jobs\b.*\bstart\b)}
    }.freeze

    def initialize(db_path:, logger:, locale: :fr, holder_finder: nil, killer: nil)
      @db_path = db_path
      @logger = logger
      @locale = locale
      @holder_finder = holder_finder || method(:default_holder_finder)
      @killer = killer || method(:default_kill)
    end

    # Raises ConfigError when a holder cannot be positively identified as an
    # orphan of ours.
    def call
      @holder_finder.call(@db_path).each { |holder| handle(holder) }
    end

    private

    def handle(holder)
      name = recognized_name(holder)
      return reap(holder, name) if name && orphaned?(holder)

      refuse(holder)
    end

    def orphaned?(holder)
      holder.ppid == 1
    end

    def recognized_name(holder)
      RECOGNIZED_COMMANDS.find { |_name, pattern| holder.command.to_s.match?(pattern) }&.first
    end

    def reap(holder, name)
      msg = Locales.t(:cli_boot_guard_reaped_orphan, locale: @locale,
                                                     name: name, pid: holder.pid, db_path: @db_path)
      @logger.warn(msg)
      @killer.call(holder.pid)
    end

    def refuse(holder)
      msg = Locales.t(:cli_boot_guard_unrecognized_holder, locale: @locale,
                                                           pid: holder.pid, command: holder.command,
                                                           db_path: @db_path)
      raise ConfigError, msg
    end

    def default_kill(pid)
      Process.kill('TERM', pid)
    rescue Errno::ESRCH
      nil # already gone
    end

    # Real implementation: `lsof` names the pids with the file (or its WAL /
    # SHM siblings) open, `ps` answers what each one is. Both are best-effort
    # — a boot must never be blocked by a diagnostic tool being unavailable,
    # so a missing binary or an unreadable pid degrades to "found nothing"
    # rather than raising.
    def default_holder_finder(db_path)
      lsof_pids(db_path).filter_map { |pid| process_info(pid) }
    end

    def lsof_pids(db_path)
      paths = [db_path, "#{db_path}-wal", "#{db_path}-shm"]
      out, status = Open3.capture2('lsof', '-t', *paths)
      return [] unless status.success?

      out.split("\n").map(&:to_i).uniq
    rescue Errno::ENOENT
      [] # lsof not installed — degrade to no-op rather than block boot
    end

    def process_info(pid)
      out, status = Open3.capture2('ps', '-o', 'ppid=,command=', '-p', pid.to_s)
      return nil unless status.success?

      line = out.strip
      return nil if line.empty?

      ppid_str, command = line.split(' ', 2)
      Holder.new(pid: pid, ppid: ppid_str.to_i, command: command.to_s)
    rescue Errno::ENOENT
      nil
    end
  end
end

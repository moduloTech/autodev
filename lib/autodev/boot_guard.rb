# frozen_string_literal: true

require 'open3'
require_relative 'process_stopper'

module Autodev
  # Autodev #92 design §2: a signal the supervisor's trap does not cover
  # (SIGKILL) leaves nothing to run, so nothing inside `Supervisor#run` can
  # help. `KeepAlive: Crashed` in the LaunchAgent plist means launchd
  # restarts the supervisor when its main process dies, and a child already
  # spawned by the dead supervisor can keep running, holding the SQLite file
  # (+ WAL/SHM) open — the ghost this ticket is named for.
  #
  # `Supervisor#run`'s own `ensure` (see supervisor.rb) closes this gap going
  # forward, for every abrupt end this *process* can still react to. This
  # class closes it for the one case that process cannot reach at all: an
  # orphan that already exists, belonging to a *different*, already-dead
  # supervisor, discovered when a fresh one boots.
  #
  # Runs once, before `Supervisor#spawn_all`.
  #
  # == What "an orphan of ours" means, and why it is not `ppid == 1`
  #
  # The first version of this guard read `ppid == 1`, on the reasoning that a
  # crashed supervisor's children are adopted by launchd. That is true of its
  # *direct* children, and the alpha-53 neutral review measured that it is not
  # the discriminator this guard needs: on the queue side the process that
  # actually holds the database is `solid-queue-worker`, a **grandchild**
  # whose parent is the fork supervisor. After a SIGKILL of the supervisor the
  # fork supervisor is reparented to pid 1, but the worker keeps its parent —
  # so `ppid == 1` never matched the very holder the guard exists to reap.
  #
  # The **process group** is the property that survives: production shows one
  # pgid for the whole tree (supervisor, puma, fork supervisor, workers), and
  # an orphaned tree keeps the dead supervisor's pgid. So a holder is an
  # abandoned child of ours when its command matches one of ours **and** its
  # pgid is not this boot's own **and** that pgid's leader — the supervisor
  # that owned the group — is gone. A live sibling supervisor's tree fails the
  # last test and is left alone.
  #
  # == Why an unidentified holder does not stop the boot
  #
  # It used to, and that made autodev unbootable. There is always a holder the
  # guard cannot identify: `run_boot_guard` runs after `bootstrap` →
  # `setup_database`, so **the booting process itself** holds the database,
  # That one is permanent and sufficient on its own. Third parties come and
  # go: the container VM danger-claude runs in was measured holding all three
  # paths on 03/09 and none of them the next day, so it is a transient holder
  # rather than a standing one — which is exactly why the answer cannot be a
  # refusal. Refusing is a total outage, repeated on every launchd restart —
  # the "boot loop … worse than the leak it replaces" this comment used to
  # claim had been avoided.
  #
  # The asymmetry is the reason: a false refusal is a total outage, a false
  # pass is one ghost process that `Supervisor#run`'s `ensure` now prevents
  # from recurring. So an unidentified holder is named in a warning and the
  # boot proceeds. `AUTODEV_BOOT_GUARD_STRICT=1` restores the refusal for an
  # operator investigating by hand.
  #
  # No holder at all is a silent pass — the common case on a clean machine.
  class BootGuard
    # One holder, as reported by `ps -o ppid=,pgid=,command=`.
    Holder = Struct.new(:pid, :ppid, :pgid, :command)

    # Matched against the *live* process title, not the argv autodev spawned
    # it with — Puma renames its own `$0` once it has bound the port (the
    # production ghost measured on 01/09 showed `puma 6.6.1 (tcp://…)`, not
    # `bin/rails server …`), and Solid Queue's fork supervisor and workers do
    # the same (`solid-queue-fork-supervisor: supervising …`,
    # `solid-queue-worker(1.4.0): waiting for jobs in *`). The `bin/rails …
    # server` / `bin/jobs … start` alternatives cover a very freshly spawned
    # orphan that has not renamed itself yet.
    RECOGNIZED_COMMANDS = {
      'rails-server' => %r{(bin/rails\b.*\bserver\b)|(^puma\b)},
      'solid-queue' => %r{solid[_-]queue|(bin/jobs\b.*\bstart\b)}
    }.freeze

    STRICT_ENV = 'AUTODEV_BOOT_GUARD_STRICT'

    # Production needs the first three; `overrides:` carries everything that
    # has a working default — `strict` and `own_pgid`, which a caller may state
    # instead of reading from the environment, and the three collaborators a
    # test stands in for (`holder_finder`, `pgid_alive`, `stopper`).
    def initialize(db_path:, logger:, locale: :fr, overrides: {})
      @db_path = db_path
      @logger = logger
      @locale = locale
      @strict = overrides[:strict].nil? ? strict_env? : overrides[:strict]
      @own_pgid = overrides[:own_pgid] || Process.getpgrp
      @holder_finder = overrides[:holder_finder] || method(:default_holder_finder)
      @pgid_alive = overrides[:pgid_alive] || method(:default_pgid_alive)
      build_stopper(overrides)
    end

    # Raises ConfigError only in strict mode, and only for a holder that
    # cannot be positively identified as an abandoned child of ours.
    def call
      @holder_finder.call(@db_path).each { |holder| handle(holder) }
    end

    private

    # `@grace` is bound once so the default `@stopper` and a future sentence
    # could share it — not threaded into the KILL sentence today, since an
    # injected `stopper:` (every test here passes one) ignores it, and a
    # number nothing threaded back is the unchecked claim Autodev #109 opened.
    def build_stopper(overrides)
      @grace = overrides[:grace] || ProcessStopper::DEFAULT_GRACE_SECONDS
      @stopper = overrides[:stopper] || ->(pid) { ProcessStopper.stop(pid, grace: @grace) }
    end

    def strict_env?
      %w[1 true yes].include?(ENV.fetch(STRICT_ENV, '').strip.downcase)
    end

    def handle(holder)
      name = recognized_name(holder)
      return reap(holder, name) if name && abandoned?(holder)

      return refuse(holder) if @strict

      @logger.warn(foreign_message(holder))
    end

    # Not ours to touch unless the group it belongs to has lost its leader.
    def abandoned?(holder)
      return false if holder.pgid == @own_pgid
      return false if holder.pgid.to_i <= 0

      !@pgid_alive.call(holder.pgid)
    end

    def recognized_name(holder)
      RECOGNIZED_COMMANDS.find { |_name, pattern| holder.command.to_s.match?(pattern) }&.first
    end

    # Discovery and outcome are two sentences on purpose. A single one would
    # have to be written before the result is known, which is how this defect
    # was born (Autodev #109): the old key ended with "Stopping it (TERM)" and
    # nothing ever checked.
    def reap(holder, name)
      @logger.warn(Locales.t(:cli_boot_guard_orphan_found, locale: @locale, name: name, pid: holder.pid,
                                                           pgid: holder.pgid, db_path: @db_path))
      announce(@stopper.call(holder.pid), holder, name)
    end

    def announce(verdict, holder, name)
      case verdict
      when :gone_on_term
        @logger.info(Locales.t(:cli_boot_guard_orphan_stopped_term, locale: @locale, name: name, pid: holder.pid))
      when :gone_on_kill
        @logger.warn(Locales.t(:cli_boot_guard_orphan_stopped_kill, locale: @locale, name: name, pid: holder.pid))
      else
        survived(holder, name)
      end
    end

    # An orphan that survives SIGKILL is remarkable, and it still does not
    # justify refusing the boot: a false refusal is a total outage repeated on
    # every launchd restart under `KeepAlive: Crashed`, a false pass is one
    # ghost process. Strict mode is where an operator investigating by hand
    # gets the refusal.
    def survived(holder, name)
      msg = Locales.t(:cli_boot_guard_orphan_survived, locale: @locale, name: name, pid: holder.pid,
                                                       command: holder.command, db_path: @db_path)
      raise ConfigError, msg if @strict

      @logger.warn(msg)
    end

    def refuse(holder)
      raise ConfigError, foreign_message(holder, strict: true)
    end

    # The ternary is written inside the call rather than assigned first so the
    # i18n key scan (Autodev #68/#73) reads both literals off this call site —
    # a key it cannot read is a key nothing checks.
    def foreign_message(holder, strict: false)
      Locales.t(strict ? :cli_boot_guard_unrecognized_holder : :cli_boot_guard_foreign_holder,
                locale: @locale, pid: holder.pid, command: holder.command, db_path: @db_path)
    end

    # `Process.kill(0, pgid)` asks "does the group leader still exist?"
    # without signalling it. EPERM means it exists and belongs to somebody
    # else, which for this question is the same as alive.
    def default_pgid_alive(pgid)
      Process.kill(0, pgid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    # Real implementation: `lsof` names the pids with the file (or its WAL /
    # SHM siblings) open, `ps` answers what each one is. Both are best-effort
    # — a boot must never be blocked by a diagnostic tool being unavailable,
    # so a missing binary or an unreadable pid degrades to "found nothing"
    # rather than raising.
    #
    # The calling process is excluded: `setup_database` has already opened the
    # database by the time this runs, so we would otherwise always find
    # ourselves.
    def default_holder_finder(db_path)
      lsof_pids(db_path)
        .reject { |pid| pid == Process.pid }
        .filter_map { |pid| process_info(pid) }
    end

    # `lsof` exits non-zero as soon as one of the named paths does not exist —
    # a database with no WAL sibling, for instance — **while still printing
    # the valid pids of the others**. Reading stdout only on a successful exit
    # turned the guard into a silent no-op in exactly that case, so the status
    # is ignored and the output is parsed for whatever it holds.
    def lsof_pids(db_path)
      paths = [db_path, "#{db_path}-wal", "#{db_path}-shm"]
      out, = Open3.capture2('lsof', '-t', *paths, err: File::NULL)
      out.split("\n").filter_map { |line| Integer(line.strip, exception: false) }.uniq
    rescue Errno::ENOENT
      [] # lsof not installed — degrade to no-op rather than block boot
    end

    def process_info(pid)
      out, status = Open3.capture2('ps', '-o', 'ppid=,pgid=,command=', '-p', pid.to_s)
      return nil unless status.success?

      line = out.strip
      return nil if line.empty?

      ppid_str, pgid_str, command = line.split(' ', 3)
      Holder.new(pid: pid, ppid: ppid_str.to_i, pgid: pgid_str.to_i, command: command.to_s)
    rescue Errno::ENOENT
      nil
    end
  end
end

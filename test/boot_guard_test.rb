# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/boot_guard'
require 'tmpdir'
require 'sqlite3'
require 'open3'

# Autodev #92 design §2: `SIGKILL` leaves nothing to run, so no in-process
# `ensure` can reach a child that was already orphaned before this boot
# started — by the time a fresh supervisor starts, that orphan belongs to a
# *different*, already-dead process. The boot guard runs once, before
# anything is spawned, and reaps what it can positively identify as an
# abandoned child of a previous supervisor.
#
# The neutral review of the alpha-53 lot rewrote what "positively identify"
# means, because the first version was unbootable:
#
#   * it read `ppid == 1`, but the process that actually holds the database
#     on the queue side is `solid-queue-worker`, a *grandchild* whose parent
#     is the fork supervisor — alive, so `ppid == 1` never matched the very
#     case the guard exists for. The discriminator is the **process group**:
#     an orphaned tree keeps the dead supervisor's pgid, and that pgid's
#     leader is gone;
#   * it refused the boot on any holder it did not recognise, and there is
#     always one — the booting process itself (`setup_database` opens the
#     database before the guard runs); third parties such as the container VM
#     hold it transiently on top. A false refusal is a total outage under
#     `KeepAlive: Crashed`; a false pass is a leak that `Supervisor#run`'s
#     `ensure` now closes going forward. So an unidentified holder warns and
#     the boot proceeds, and refusing is opt-in (`AUTODEV_BOOT_GUARD_STRICT`).
#
# `overrides:` carries the injection seams for the classification
# logic; `test_the_real_holder_finder_*` tests exercise the actual `lsof` +
# `ps` shell-outs against a real subprocess, which is what no test did before.
# rubocop:disable Metrics/ClassLength -- the three `test_the_real_holder_finder_*`
# cases carry a real subprocess harness (temp WAL database, readiness file,
# teardown), which is the point: nothing exercised the real finder before.
class BootGuardTest < Minitest::Test
  # Drop-in replacement for AppLogger so we can assert on emissions.
  class FakeLogger
    attr_reader :entries

    def initialize
      @entries = []
    end

    %i[info warn error debug].each do |level|
      define_method(level) { |msg, **_| @entries << [level, msg] }
    end
  end

  OUR_PGID = 4242
  DEAD_PGID = 1176

  def setup
    @logger = FakeLogger.new
    @killed = []
    @verdict = :gone_on_term
    @stopper = lambda do |pid|
      @killed << pid
      @verdict
    end
  end

  # --- what gets reaped -----------------------------------------------------

  def test_a_recognized_rails_server_orphan_is_reaped_and_logged
    # The exact process title production measured post-boot (puma renames its
    # own $0 once it has bound the port).
    holder = build_holder(pid: 555, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')
    guard = build_guard(holders: [holder])

    guard.call

    assert_equal [555], @killed, 'a recognised orphan must be reaped'
    # `entries` is an Array of [level, msg] pairs, not a Hash — Style/HashSlice's
    # autocorrect misread this `select` as a Hash#slice candidate, which would
    # raise (Array#slice takes an index/range, not a key). rubocop:disable
    warn_lines = @logger.entries.select { |level, _| level == :warn } # rubocop:disable Style/HashSlice

    assert(warn_lines.any? { |_, msg| msg.include?('555') }, 'the reap must be logged, naming the pid')
  end

  def test_the_solid_queue_grandchild_is_reaped_even_though_its_parent_is_alive
    # G1(c) of the neutral review, and the whole point of moving off `ppid`:
    # after a SIGKILL of the supervisor, the fork supervisor is reparented to
    # pid 1 but `solid-queue-worker` — the only one of the two that holds the
    # database — keeps its parent, which is that fork supervisor. Under the
    # old `ppid == 1` rule this holder was refused rather than reaped.
    holder = build_holder(pid: 1402, ppid: 1384, command: 'solid-queue-worker(1.4.0): waiting for jobs in *')
    guard = build_guard(holders: [holder])

    guard.call

    assert_equal [1402], @killed
  end

  def test_both_children_are_reaped_in_the_same_pass
    rails_orphan = build_holder(pid: 555, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')
    queue_orphan = build_holder(pid: 556, command: 'solid-queue-fork-supervisor: supervising 1401')
    guard = build_guard(holders: [rails_orphan, queue_orphan])

    guard.call

    assert_equal [555, 556], @killed.sort
  end

  def test_an_orphan_that_honours_term_is_reported_stopped_without_a_kill
    @verdict = :gone_on_term
    guard = build_guard(holders: [build_holder(pid: 555, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')])

    guard.call

    assert_equal [555], @killed
    assert(messages.any? { |m| m.include?('555') && m.match?(/SIGTERM|TERM/) },
           'the outcome must be stated, and it must name the pid')
  end

  def test_an_orphan_that_ignores_term_reports_the_kill
    @verdict = :gone_on_kill
    guard = build_guard(holders: [build_holder(pid: 555, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')])

    guard.call

    kill_lines = @logger.entries.select { |level, msg| level == :warn && msg.include?('555') }

    refute_empty kill_lines, 'a straggler killed after the grace must be visible at warn level'
  end

  # The 03/09 case: the boot must NOT stop, and the pid must be named.
  def test_an_orphan_that_survives_kill_warns_and_lets_the_boot_proceed
    @verdict = :alive
    guard = build_guard(holders: [build_holder(pid: 1383, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')])

    guard.call # must not raise

    assert(messages.any? { |m| m.include?('1383') },
           'a surviving orphan must be named so an operator can find it')
  end

  def test_the_discovery_sentence_no_longer_announces_a_stop
    @verdict = :alive
    guard = build_guard(holders: [build_holder(pid: 1383, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')])

    guard.call

    refute(messages.any? { |m| m.include?('Stopping it (TERM)') },
           'the discovery sentence must not claim an outcome it has not observed')
  end

  # --- what gets left alone -------------------------------------------------

  def test_an_unrecognized_process_holding_the_database_warns_and_lets_the_boot_proceed
    # A third-party holder, measured once on the production host (the
    # container VM danger-claude runs in). Refusing here is the boot loop the
    # guard was supposed to avoid.
    holder = build_holder(pid: 777, command: '/System/…/com.apple.Virtualization.VirtualMachine')
    guard = build_guard(holders: [holder])

    guard.call # must not raise

    assert_empty @killed, 'an unidentified holder must never be killed'
    assert(@logger.entries.any? { |level, msg| level == :warn && msg.include?('777') },
           'an unidentified holder must be named in a warning')
  end

  def test_a_recognized_child_of_a_live_supervisor_is_left_alone
    # A different, still-running supervisor: its pgid leader answers, so the
    # tree is not abandoned and is none of this boot's business.
    holder = build_holder(pid: 558, pgid: 9999, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)',
                          live_pgids: [9999])
    guard = build_guard(holders: [holder], live_pgids: [9999])

    guard.call

    assert_empty @killed, "a live supervisor's child must not be reaped"
    assert(@logger.entries.any? { |level, _| level == :warn })
  end

  def test_a_holder_in_our_own_process_group_is_left_alone
    # Whatever this boot itself is holding open — the guard must never reap
    # its own tree, however well its command matches.
    holder = build_holder(pid: 559, pgid: OUR_PGID, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')
    guard = build_guard(holders: [holder])

    guard.call

    assert_empty @killed, 'the guard must never reap something in its own process group'
  end

  def test_nothing_holding_the_database_is_a_silent_pass
    guard = build_guard(holders: [])

    guard.call

    assert_empty @killed
    assert_empty @logger.entries
  end

  # --- refusing is opt-in ---------------------------------------------------

  def test_strict_mode_refuses_the_boot_on_an_unidentified_holder
    holder = build_holder(pid: 777, command: '/usr/bin/some-other-tool --scan')
    guard = build_guard(holders: [holder], strict: true)

    error = assert_raises(ConfigError) { guard.call }

    assert_includes error.message, '777'
    assert_empty @killed
  end

  def test_strict_mode_still_reaps_what_it_recognises
    holder = build_holder(pid: 555, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')
    guard = build_guard(holders: [holder], strict: true)

    guard.call

    assert_equal [555], @killed
  end

  # --- the real finder, which nothing exercised before ----------------------

  def test_the_real_holder_finder_never_reports_the_calling_process
    # Mechanism (a) of G1: `run_boot_guard` runs after `setup_database`, so
    # the booting process holds the database itself. `lsof` lists it, `ps`
    # answers `ruby …/bin/autodev`, which matches no pattern — under the old
    # code that alone refused every boot.
    #
    # The first version of this test closed its own handle before looking, so
    # the calling process held nothing and it passed with the exclusion
    # removed (second neutral review, N7). It now holds the database open for
    # the duration, which is the state a real boot is in, and is red without
    # the `reject { pid == Process.pid }`.
    with_held_database do |db_path, _child_pid|
      holding_it_ourselves(db_path) do
        assert_includes lsof_pids_for(db_path), Process.pid,
                        'precondition: this process must really hold the database'
        refute_includes real_finder_pids(db_path), Process.pid,
                        'the finder must exclude the calling process'
      end
    end
  end

  def test_the_real_holder_finder_finds_a_foreign_holder_with_its_group
    with_held_database do |db_path, child_pid|
      holders = real_finder(db_path)
      found = holders.find { |h| h.pid == child_pid }

      refute_nil found, 'the finder must see a subprocess holding the database'
      assert_operator found.pgid, :>, 0, 'the holder must carry a process group id'
      assert_includes found.command, 'ruby', "the holder's command must be resolved"
    end
  end

  def test_the_real_holder_finder_reads_lsof_output_even_when_a_path_is_missing
    # Sub-finding of G1: `lsof` exits non-zero as soon as one named path does
    # not exist, *while still printing the valid pids of the others*. Reading
    # only on a successful exit made the guard a silent no-op — the opposite
    # failure of the one above, and just as bad.
    with_held_database(wal: false) do |db_path, child_pid|
      refute_path_exists "#{db_path}-wal", 'this test needs a database with no WAL sibling'

      assert_includes real_finder_pids(db_path), child_pid,
                      'a missing -wal path must not blind the finder'
    end
  end

  private

  def build_holder(pid:, command:, ppid: 1, pgid: DEAD_PGID, live_pgids: nil)
    _ = live_pgids
    Autodev::BootGuard::Holder.new(pid: pid, ppid: ppid, pgid: pgid, command: command)
  end

  def build_guard(holders:, strict: false, live_pgids: [])
    Autodev::BootGuard.new(
      db_path: '/home/x/.autodev/autodev.db',
      logger: @logger,
      locale: :en,
      overrides: { strict: strict, own_pgid: OUR_PGID,
                   holder_finder: ->(_db_path) { holders },
                   pgid_alive: ->(pgid) { live_pgids.include?(pgid) },
                   stopper: @stopper }
    )
  end

  def messages = @logger.entries.map(&:last)

  # The real `default_holder_finder`, reached through a guard built with no
  # `holder_finder:` override.
  def real_finder(db_path)
    guard = Autodev::BootGuard.new(db_path: db_path, logger: @logger, locale: :en)
    guard.send(:default_holder_finder, db_path)
  end

  def real_finder_pids(db_path)
    real_finder(db_path).map(&:pid)
  end

  # An open handle in *this* process, which is what a real boot holds by the
  # time the guard runs.
  def holding_it_ourselves(db_path)
    own = SQLite3::Database.new(db_path)
    own.execute('INSERT INTO t VALUES (3)')
    yield
  ensure
    own&.close
  end

  # Raw `lsof`, deliberately not the code under test: the precondition of the
  # test above must not be established by the method it is testing.
  def lsof_pids_for(db_path)
    paths = [db_path, "#{db_path}-wal", "#{db_path}-shm"]
    out, = Open3.capture2('lsof', '-t', *paths, err: File::NULL)
    out.split("\n").filter_map { |line| Integer(line.strip, exception: false) }
  end

  # Spawns a child that opens `db_path` and keeps it open until we kill it,
  # so the finder has a genuine foreign holder to report. `wal: false` leaves
  # the database in its default journal mode, so no `-wal`/`-shm` siblings
  # exist and `lsof` will exit non-zero on them.
  def with_held_database(wal: true, &)
    Dir.mktmpdir('boot-guard') do |dir|
      db_path = File.join(dir, 'autodev.db')
      seed_database(db_path, wal: wal)
      ready = File.join(dir, 'ready')
      child = spawn_holder(db_path, ready, wal: wal)
      wait_for(ready)
      yield_to_holder(db_path, child, &)
    end
  end

  def yield_to_holder(db_path, child)
    yield db_path, child
  ensure
    stop_holder(child)
  end

  def seed_database(db_path, wal:)
    db = SQLite3::Database.new(db_path)
    db.execute('PRAGMA journal_mode=WAL') if wal
    db.execute('CREATE TABLE t (a integer)')
    db.execute('INSERT INTO t VALUES (1)')
    db.close
  end

  def spawn_holder(db_path, ready_path, wal:)
    spawn(RbConfig.ruby, '-e', holder_script(db_path, ready_path, wal: wal),
          out: File::NULL, err: File::NULL)
  end

  def holder_script(db_path, ready_path, wal:)
    <<~RUBY
      require 'sqlite3'
      db = SQLite3::Database.new(#{db_path.inspect})
      db.execute('PRAGMA journal_mode=WAL') if #{wal}
      db.execute('INSERT INTO t VALUES (2)')
      File.write(#{ready_path.inspect}, 'ok')
      sleep 60
    RUBY
  end

  def wait_for(path, timeout: 15)
    deadline = Time.now + timeout
    sleep 0.05 until File.exist?(path) || Time.now > deadline
    raise "holder subprocess never signalled ready (#{path})" unless File.exist?(path)
  end

  def stop_holder(pid)
    Process.kill('TERM', pid)
  rescue Errno::ESRCH
    nil
  ensure
    begin
      Process.wait(pid)
    rescue Errno::ECHILD
      nil
    end
  end
end
# rubocop:enable Metrics/ClassLength

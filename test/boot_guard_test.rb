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

  # The anchor `assert_outcomes_do_not_cross_contaminate` checks each locale's
  # KILL sentence for, and the TERM sentence's absence of (see that method).
  ESCALATION_WORD = { en: 'escalated', fr: 'dépassé' }.freeze

  def setup
    @logger = FakeLogger.new
    @stopped = []
    @verdict = :gone_on_term
    @stopper = lambda do |pid|
      @stopped << pid
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

    assert_equal [555], @stopped, 'a recognised orphan must be reaped'
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

    assert_equal [1402], @stopped
  end

  def test_both_children_are_reaped_in_the_same_pass
    rails_orphan = build_holder(pid: 555, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')
    queue_orphan = build_holder(pid: 556, command: 'solid-queue-fork-supervisor: supervising 1401')
    guard = build_guard(holders: [rails_orphan, queue_orphan])

    guard.call

    assert_equal [555, 556], @stopped.sort
  end

  def test_an_orphan_that_honours_term_is_reported_stopped_without_a_kill
    @verdict = :gone_on_term
    guard = build_guard(holders: [build_holder(pid: 555, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')])

    guard.call

    assert_equal [555], @stopped
    assert(messages.any? { |m| m.include?('555') && m.match?(/SIGTERM|TERM/) },
           'the outcome must be stated, and it must name the pid')
  end

  def test_an_orphan_that_ignores_term_reports_the_kill
    # The discovery sentence is *also* a warn line naming pid 555 (it is
    # logged before the stopper is even called), so "some warn line mentions
    # the pid" is satisfied whether or not `announce` ever runs. Asserting the
    # exact rendered `cli_boot_guard_orphan_stopped_kill` text is the only way
    # to name the sentence this test is actually about.
    @verdict = :gone_on_kill
    guard = build_guard(holders: [build_holder(pid: 555, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')])

    guard.call

    expected = Locales.t(:cli_boot_guard_orphan_stopped_kill, locale: :en, name: 'rails-server', pid: 555)

    assert_includes @logger.entries, [:warn, expected],
                    'a straggler killed after the grace must state the escalation, at warn level'
  end

  # The 03/09 case: the boot must NOT stop, and the pid must be named.
  def test_an_orphan_that_survives_kill_warns_and_lets_the_boot_proceed
    # Same trap as the kill test above: the discovery sentence already names
    # pid 1383 at warn level, so a bare `messages.any? { include?('1383') }`
    # passes with `announce`/`survived` never called. Assert the rendered
    # `cli_boot_guard_orphan_survived` text specifically.
    @verdict = :alive
    holder = build_holder(pid: 1383, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')
    guard = build_guard(holders: [holder])

    guard.call # must not raise

    expected = Locales.t(:cli_boot_guard_orphan_survived, locale: :en, name: 'rails-server', pid: 1383,
                                                          command: holder.command,
                                                          db_path: '/home/x/.autodev/autodev.db')

    assert_includes @logger.entries, [:warn, expected],
                    'a surviving orphan must be named so an operator can find it'
  end

  def test_the_discovery_sentence_no_longer_announces_a_stop
    @verdict = :alive
    guard = build_guard(holders: [build_holder(pid: 1383, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')])

    guard.call

    refute(messages.any? { |m| m.include?('Stopping it (TERM)') },
           'the discovery sentence must not claim an outcome it has not observed')
  end

  # Design spec Testing §5: "the three outcome sentences are distinct and each
  # is logged only on its own verdict." Written after the alpha-53 review
  # found no test that would fail if the locale file assigned the TERM text to
  # the KILL key and vice versa — every existing test only checked that *a*
  # message named the pid, not *which* message.
  #
  # `assert_equal` against `Locales.t(<the key this verdict's branch calls>)`
  # cannot catch a mis-swapped locale *file* by itself: it reads the same
  # (possibly wrong) text on both sides of the comparison, because the key
  # `announce` dispatches to for a given verdict is a property of this file,
  # not of the locale file. What a locale swap breaks is the *meaning* of the
  # text at each key, so the second half of this test checks the one thing
  # that does not move with a swap: the words that name what actually
  # happened, in the locale actually rendered — checked in **both** `:en` and
  # `:fr`, not `:en` alone (the neutral review of the alpha-54 lot: the first
  # version of this test rendered `:en` only, while `BootGuard`'s default is
  # `:fr` and production configures `web.locale: fr` — so a swap of the exact
  # pair this test exists to catch, made in `cli.fr.yml`, the file the
  # deployed sentence actually reads, left the whole suite green).
  def test_the_three_outcomes_are_distinct_and_only_the_matching_one_is_logged
    holder = build_holder(pid: 555, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')

    %i[en fr].each do |locale|
      rendered = observed_outcome_messages(holder, locale: locale)

      assert_outcomes_match_their_own_locale_key(rendered, holder, locale)
      assert_outcomes_do_not_cross_contaminate(rendered, locale)
    end
  end

  # --- the default stopper, which every other test bypasses -----------------

  # Every `build_guard` above injects `stopper:`, so the real default —
  # `->(pid) { ProcessStopper.stop(pid, grace: @grace) }` — is dead code as
  # far as the rest of this file is concerned, and a signature drift between
  # `BootGuard` and `ProcessStopper.stop` would only surface in production.
  # This drives it against a real subprocess that ignores SIGTERM, the same
  # harness `test/process_stopper_test.rb#with_stubborn_child` uses one layer
  # down — `grace: 1` (via `overrides:`) keeps it fast without touching the
  # production default.
  def test_the_real_default_stopper_escalates_against_a_process_that_ignores_term
    with_stubborn_orphan do |pid|
      real_stopper_guard_for(pid).call

      assert_includes @logger.entries, [:warn, kill_message_for(pid)]
      assert_raises(Errno::ESRCH, 'the real stopper must really have killed it') { Process.kill(0, pid) }
    end
  end

  # --- what gets left alone -------------------------------------------------

  def test_an_unrecognized_process_holding_the_database_warns_and_lets_the_boot_proceed
    # A third-party holder, measured once on the production host (the
    # container VM danger-claude runs in). Refusing here is the boot loop the
    # guard was supposed to avoid.
    holder = build_holder(pid: 777, command: '/System/…/com.apple.Virtualization.VirtualMachine')
    guard = build_guard(holders: [holder])

    guard.call # must not raise

    assert_empty @stopped, 'an unidentified holder must never be handed to the stopper'
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

    assert_empty @stopped, "a live supervisor's child must not be reaped"
    assert(@logger.entries.any? { |level, _| level == :warn })
  end

  def test_a_holder_in_our_own_process_group_is_left_alone
    # Whatever this boot itself is holding open — the guard must never reap
    # its own tree, however well its command matches.
    holder = build_holder(pid: 559, pgid: OUR_PGID, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')
    guard = build_guard(holders: [holder])

    guard.call

    assert_empty @stopped, 'the guard must never reap something in its own process group'
  end

  def test_nothing_holding_the_database_is_a_silent_pass
    guard = build_guard(holders: [])

    guard.call

    assert_empty @stopped
    assert_empty @logger.entries
  end

  # --- refusing is opt-in ---------------------------------------------------

  def test_strict_mode_refuses_the_boot_on_an_unidentified_holder
    holder = build_holder(pid: 777, command: '/usr/bin/some-other-tool --scan')
    guard = build_guard(holders: [holder], strict: true)

    error = assert_raises(ConfigError) { guard.call }

    assert_includes error.message, '777'
    assert_empty @stopped
  end

  def test_strict_mode_still_reaps_what_it_recognises
    holder = build_holder(pid: 555, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')
    guard = build_guard(holders: [holder], strict: true)

    guard.call

    assert_equal [555], @stopped
  end

  def test_strict_mode_refuses_when_an_orphan_survives_kill
    @verdict = :alive
    guard = build_guard(holders: [build_holder(pid: 1383, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')],
                        strict: true)

    error = assert_raises(ConfigError) { guard.call }

    assert_includes error.message, '1383'
  end

  def test_strict_mode_does_not_refuse_after_a_successful_reap
    @verdict = :gone_on_kill
    guard = build_guard(holders: [build_holder(pid: 555, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')],
                        strict: true)

    guard.call # must not raise: an operator investigating by hand must still be able to boot

    assert_equal [555], @stopped
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

  def build_guard(holders:, strict: false, live_pgids: [], locale: :en)
    Autodev::BootGuard.new(
      db_path: '/home/x/.autodev/autodev.db',
      logger: @logger,
      locale: locale,
      overrides: { strict: strict, own_pgid: OUR_PGID,
                   holder_finder: ->(_db_path) { holders },
                   pgid_alive: ->(pgid) { live_pgids.include?(pgid) },
                   stopper: @stopper }
    )
  end

  def messages = @logger.entries.map(&:last)

  # --- helpers for test_the_three_outcomes_are_distinct_and_only_the_matching_one_is_logged --

  def outcome_keys
    { gone_on_term: :cli_boot_guard_orphan_stopped_term,
      gone_on_kill: :cli_boot_guard_orphan_stopped_kill,
      alive: :cli_boot_guard_orphan_survived }
  end

  def observed_outcome_messages(holder, locale:)
    outcome_keys.each_with_object({}) do |(verdict, _key), acc|
      @logger = FakeLogger.new
      @verdict = verdict
      guard = build_guard(holders: [holder], locale: locale)

      guard.call

      # `reap` always logs discovery first and the outcome second (two
      # sentences on purpose, Autodev #109) — the outcome is the last entry.
      acc[verdict] = messages.last
    end
  end

  def assert_outcomes_match_their_own_locale_key(rendered, holder, locale)
    outcome_keys.each_key do |verdict|
      assert_equal expected_outcome_message(verdict, holder, locale), rendered[verdict]
    end
  end

  def expected_outcome_message(verdict, holder, locale)
    extra = verdict == :alive ? { command: holder.command, db_path: '/home/x/.autodev/autodev.db' } : {}
    Locales.t(outcome_keys[verdict], locale: locale, name: 'rails-server', pid: holder.pid, **extra)
  end

  # The full-string checks above cannot, by themselves, catch a locale file
  # that assigned the TERM key's text to the KILL key (or vice versa): the
  # "expected" side is read through the same `Locales.t` call as the "actual"
  # side, so a swap changes both identically and the equality still holds.
  # These checks anchor on the one thing that does not move with such a
  # swap — the words that actually name what happened, in the locale actually
  # under test rather than in English alone (Autodev #109 review round two):
  # `observed_outcome_messages` used to render `:en` only, so a swap of the
  # TERM/KILL pair in `cli.fr.yml` left every test in the suite green — the
  # deployed sentence is `:fr` (`BootGuard`'s default, and what
  # `bin/autodev:473` passes from `web.locale`), so that was the one locale
  # this guard did not cover.
  #
  # `ESCALATION_WORD` is the anchor: since Autodev #109's follow-up correction
  # (a `:gone_on_kill` sentence must not claim a kill that may not have
  # happened — `ProcessStopper#stop`'s KILL-vs-ESRCH race), the KILL sentence
  # names the *escalation past the grace period* rather than a kill, in both
  # locales, and the TERM sentence names neither. "SIGKILL" itself is
  # reserved for `:alive`, which is the one verdict that names the signal it
  # survived, in both locales.
  def assert_outcomes_do_not_cross_contaminate(rendered, locale)
    escalation = ESCALATION_WORD.fetch(locale)

    assert_equal rendered.values.uniq.length, rendered.size, 'the three outcomes must render distinct sentences'
    refute_includes rendered[:gone_on_term], escalation, 'a TERM stop must not claim an escalation past the grace'
    refute_includes rendered[:gone_on_term], 'SIGKILL', 'a TERM stop must not name an escalation that never happened'
    assert_includes rendered[:gone_on_kill], escalation, 'a KILL escalation must say it escalated past the grace'
    refute_includes rendered[:gone_on_kill], 'SIGKILL',
                    "the KILL sentence names the escalation delivered, not survival — that's :alive's word"
    assert_includes rendered[:alive], 'SIGKILL', 'a surviving orphan must name the signal it survived'
  end

  # --- helpers for test_the_real_default_stopper_escalates_against_a_process_that_ignores_term --

  def real_stopper_guard_for(pid)
    holder = build_holder(pid: pid, command: 'puma 6.6.1 (tcp://0.0.0.0:4567)')
    Autodev::BootGuard.new(
      db_path: '/home/x/.autodev/autodev.db', logger: @logger, locale: :en,
      overrides: { own_pgid: OUR_PGID, holder_finder: ->(_db_path) { [holder] },
                   pgid_alive: ->(_pgid) { false }, grace: 1 }
    )
  end

  def kill_message_for(pid)
    Locales.t(:cli_boot_guard_orphan_stopped_kill, locale: :en, name: 'rails-server', pid: pid)
  end

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

  # Modelled on `with_stubborn_child` in test/process_stopper_test.rb, for
  # MINOR 4's own harness rather than a shared one: a real child that traps
  # and ignores TERM, a readiness file, and `Process.detach` so a killed child
  # doesn't sit as an unreaped zombie — which `Process.kill(0, pid)` would
  # still report alive, defeating the very assertion this test makes.
  def with_stubborn_orphan
    Dir.mktmpdir('boot-guard-stubborn-orphan') do |dir|
      pid = spawn_stubborn_orphan(dir)
      begin
        yield pid
      ensure
        force_reap_stubborn_orphan(pid)
      end
    end
  end

  def spawn_stubborn_orphan(dir)
    ready = File.join(dir, 'ready')
    pid = spawn(RbConfig.ruby, '-e', stubborn_orphan_script(ready), out: File::NULL, err: File::NULL)
    Process.detach(pid)
    wait_for(ready)
    pid
  end

  def stubborn_orphan_script(ready_path)
    <<~RUBY
      Signal.trap('TERM') { }
      File.write(#{ready_path.inspect}, 'ok')
      sleep 60
    RUBY
  end

  def force_reap_stubborn_orphan(pid)
    Process.kill('KILL', pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil # already gone, which is the normal path after a successful stop
  end
end
# rubocop:enable Metrics/ClassLength

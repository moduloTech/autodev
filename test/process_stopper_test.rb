# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/process_stopper'
require 'tmpdir'
require 'rbconfig'

# Autodev #109: `BootGuard#reap` sent one TERM, logged "Arrêt en cours (TERM)"
# and moved on. The alpha-52 puma survived that TERM for forty minutes, holding
# the production database, its WAL and its shared-memory file open for writing.
#
# This module is the escalation the guard did not have, on a **bare pid**:
# `Supervisor#force_kill_stragglers` ends in `Process.wait`, which raises
# `ECHILD` on an orphan that belongs to init. Liveness is `Process.kill(0, pid)`
# and nothing here ever reaps.
#
# rubocop:disable Metrics/ClassLength -- the two `test_a_real_subprocess_*`
# cases carry a real subprocess harness (temp dir, readiness file, teardown),
# which is the point: every other test here injects a killer that kills
# nothing, so none of them ever had a real process to observe.
class ProcessStopperTest < Minitest::Test
  def setup
    @signals = []
    @now = 0.0
  end

  # A clock that only moves when the sleeper is called, so a test drives the
  # deadline explicitly instead of waiting on the wall clock.
  def seams(alive:)
    { alive: alive,
      killer: lambda do |sig, pid|
        @signals << [sig, pid]
        true
      end,
      sleeper: ->(seconds) { @now += seconds },
      clock: -> { @now } }
  end

  def test_a_process_that_honours_term_is_gone_without_a_kill
    calls = 0
    alive = lambda do |_pid|
      calls += 1
      calls <= 1 # alive on the first look, gone on the second
    end

    verdict = Autodev::ProcessStopper.stop(555, grace: 10, overrides: seams(alive: alive))

    assert_equal :gone_on_term, verdict
    assert_equal [['TERM', 555]], @signals, 'a process that honours TERM must never be KILLed'
  end

  def test_a_process_that_ignores_term_is_killed_after_the_grace
    kills = 0
    alive = lambda do |_pid|
      # Alive until KILL is sent, gone on the first look after it.
      !@signals.include?(['KILL', 555]) || (kills += 1) < 1
    end

    verdict = Autodev::ProcessStopper.stop(555, grace: 1, overrides: seams(alive: alive))

    assert_equal :gone_on_kill, verdict
    assert_equal [['TERM', 555], ['KILL', 555]], @signals
  end

  def test_a_process_that_survives_kill_is_reported_alive
    verdict = Autodev::ProcessStopper.stop(555, grace: 1, overrides: seams(alive: ->(_pid) { true }))

    assert_equal :alive, verdict
    assert_equal [['TERM', 555], ['KILL', 555]], @signals,
                 'both signals must have been attempted before giving up'
  end

  def test_a_pid_already_gone_when_term_is_sent_is_gone_on_term
    overrides = seams(alive: ->(_pid) { true })
    overrides[:killer] = lambda do |sig, pid|
      @signals << [sig, pid]
      false # ESRCH
    end

    verdict = Autodev::ProcessStopper.stop(555, grace: 1, overrides: overrides)

    assert_equal :gone_on_term, verdict
    assert_equal [['TERM', 555]], @signals, 'a pid that was already gone needs no KILL'
  end

  # The mirror of the TERM case above: the process outlasts the whole TERM
  # grace window (`alive` never says otherwise), but by the time KILL is sent
  # it has died on its own — the killer answers ESRCH (`false`) rather than
  # confirming delivery.
  def test_a_pid_already_gone_when_kill_is_sent_is_gone_on_kill
    overrides = seams(alive: ->(_pid) { true })
    overrides[:killer] = lambda do |sig, pid|
      @signals << [sig, pid]
      sig != 'KILL' # TERM is delivered; KILL finds the pid already gone (ESRCH)
    end

    verdict = Autodev::ProcessStopper.stop(555, grace: 1, overrides: overrides)

    assert_equal :gone_on_kill, verdict
    assert_equal [['TERM', 555], ['KILL', 555]], @signals,
                 'KILL must still be attempted after the TERM grace expires'
  end

  def test_the_default_grace_matches_the_supervisors
    require 'autodev/supervisor'

    assert_equal Autodev::Supervisor::TERM_GRACE_SECONDS,
                 Autodev::ProcessStopper::DEFAULT_GRACE_SECONDS,
                 'the two escalations must not drift apart by accident'
  end

  # --- against a real process, which is the only thing that could have caught
  # --- the defect this ticket is about --------------------------------------

  def test_a_real_subprocess_ignoring_sigterm_is_killed
    with_stubborn_child do |pid|
      verdict = Autodev::ProcessStopper.stop(pid, grace: 1)

      assert_equal :gone_on_kill, verdict
      assert_raises(Errno::ESRCH, 'the process must really be gone') { Process.kill(0, pid) }
    end
  end

  def test_a_real_subprocess_honouring_sigterm_is_gone_without_a_kill
    with_stubborn_child(ignore_term: false) do |pid|
      verdict = Autodev::ProcessStopper.stop(pid, grace: 5)

      assert_equal :gone_on_term, verdict
    end
  end

  private

  # Modelled on `spawn_holder` / `with_held_database` in test/boot_guard_test.rb:
  # a real Ruby child, a readiness file so the test never races the trap being
  # installed, and an `ensure` that KILLs whatever survived the assertions.
  #
  # `Process.detach(pid)` is the one addition beyond that model, and it is
  # load-bearing: `ProcessStopper` deliberately never calls `Process.wait`
  # (its own boot-guard target is an orphan that init reaps), but *this* pid
  # really is our child. Left un-reaped, a killed child sits as a zombie —
  # which `Process.kill(0, pid)` still reports as alive — for as long as
  # nobody waits on it, so `stop`'s post-KILL confirmation window would never
  # observe it as gone and would report `:alive` on a process that is, in
  # fact, dead. `detach` starts a background thread that reaps it the moment
  # it exits, standing in for init's immediate reap of a real orphan.
  def with_stubborn_child(ignore_term: true) # rubocop:disable Metrics/MethodLength
    Dir.mktmpdir('process-stopper') do |dir|
      ready = File.join(dir, 'ready')
      pid = spawn(RbConfig.ruby, '-e', child_script(ready, ignore_term: ignore_term),
                  out: File::NULL, err: File::NULL)
      Process.detach(pid)
      wait_for_readiness(ready)
      begin
        yield pid
      ensure
        force_reap(pid)
      end
    end
  end

  def child_script(ready_path, ignore_term:)
    <<~RUBY
      Signal.trap('TERM') { } if #{ignore_term}
      File.write(#{ready_path.inspect}, 'ok')
      sleep 60
    RUBY
  end

  def wait_for_readiness(path, timeout: 10)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    sleep 0.05 until File.exist?(path) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    raise "child never became ready (#{path})" unless File.exist?(path)
  end

  def force_reap(pid)
    Process.kill('KILL', pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil # already gone, which is the normal path after a successful stop
  end
end
# rubocop:enable Metrics/ClassLength

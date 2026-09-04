# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/process_stopper'

# Autodev #109: `BootGuard#reap` sent one TERM, logged "Arrêt en cours (TERM)"
# and moved on. The alpha-52 puma survived that TERM for forty minutes, holding
# the production database, its WAL and its shared-memory file open for writing.
#
# This module is the escalation the guard did not have, on a **bare pid**:
# `Supervisor#force_kill_stragglers` ends in `Process.wait`, which raises
# `ECHILD` on an orphan that belongs to init. Liveness is `Process.kill(0, pid)`
# and nothing here ever reaps.
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

  def test_the_default_grace_matches_the_supervisors
    require 'autodev/supervisor'

    assert_equal Autodev::Supervisor::TERM_GRACE_SECONDS,
                 Autodev::ProcessStopper::DEFAULT_GRACE_SECONDS,
                 'the two escalations must not drift apart by accident'
  end
end

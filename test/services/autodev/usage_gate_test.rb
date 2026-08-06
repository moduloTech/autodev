# frozen_string_literal: true

require_relative '../../rails_helper'

# `UsageChecker` lives in lib/autodev, which AUTODEV_SKIP_LEGACY=1 keeps out of
# the AR test world (same reason as test/jobs/autodev_poll_job_test.rb). The
# gate only ever calls `.new(logger:).available?`, so a bare stand-in is enough
# for `UsageChecker.stub` to resolve.
Object.const_set(:UsageChecker, Class.new { def self.new(**); end }) unless defined?(UsageChecker)

# Autodev::UsageGate — the shared Claude-quota state (Autodev #46).
#
# The poll cycle probes once and persists the verdict; every consumer
# (PollDispatcher, PipelineMonitor, IssueProcessJob, the dashboard) reads that
# persisted state instead of shelling out to danger-claude itself.
class UsageGateTest < ActiveSupport::TestCase
  CONFIG = { 'poll_interval' => 300 }.freeze

  def stub_checker(available, &)
    verdict = available.respond_to?(:call) ? available : ->(*) { available }
    checker = Object.new
    checker.define_singleton_method(:available?) { instance_exec(&verdict) }
    UsageChecker.stub(:new, checker, &)
  end

  def usage_event(available:, age_seconds: 0)
    ActivityEvent.create!(
      issue_id: nil, kind: 'usage', level: available ? 'info' : 'warn',
      payload_json: JSON.generate(available: available),
      created_at: Time.now.utc - age_seconds
    )
  end

  def gate_state(**)
    Autodev::UsageGate.state(config: CONFIG, **)
  end

  def available?(**)
    Autodev::UsageGate.available?(config: CONFIG, **)
  end

  # --- probe! -------------------------------------------------------------

  def probed_event(available)
    stub_checker(available) { Autodev::UsageGate.probe!(logger: Logger.new(IO::NULL)) }
    ActivityEvent.where(kind: 'usage').order(:id).last
  end

  test 'probe! persists the verdict as a system usage event' do
    event = probed_event(false)

    assert_nil event.issue_id
    refute event.payload['available']
  end

  test 'probe! records the exhausted verdict at warn level' do
    assert_equal 'warn', probed_event(false).level
  end

  test 'probe! returns the verdict' do
    stub_checker(true) do
      assert Autodev::UsageGate.probe!(logger: Logger.new(IO::NULL))
    end
    stub_checker(false) do
      refute Autodev::UsageGate.probe!(logger: Logger.new(IO::NULL))
    end
  end

  test 'probe! records level info when the quota is available' do
    assert_equal 'info', probed_event(true).level
  end

  # A broken probe must never be what stops the pipeline — same fail-open the
  # old `AutodevPollJob#usage_paused?` rescue had.
  test 'probe! fails open when the checker raises' do
    stub_checker(->(*) { raise StandardError, 'boom' }) do
      assert Autodev::UsageGate.probe!(logger: Logger.new(IO::NULL))
    end
  end

  # --- available? / state -------------------------------------------------

  test 'available? reads the latest persisted verdict' do
    usage_event(available: true, age_seconds: 120)
    usage_event(available: false)

    refute_predicate self, :available?
  end

  test 'available? is true when the quota was available at the last probe' do
    usage_event(available: true)

    assert_predicate self, :available?
  end

  test 'available? fails open when no probe was ever recorded' do
    assert_predicate self, :available?
  end

  # A stale verdict says nothing about now: a stopped poller must not freeze
  # every consumer on a days-old "exhausted".
  test 'available? fails open on a stale verdict' do
    usage_event(available: false, age_seconds: 5_000)

    assert_predicate self, :available?
  end

  test 'available? honours a fresh verdict inside the TTL' do
    usage_event(available: false, age_seconds: 60)

    refute_predicate self, :available?
  end

  # TTL = max(2 × poll_interval, 600s) — the floor keeps a tight interval from
  # making the state expire between two cycles.
  test 'the ttl floor keeps a short poll interval from expiring the state' do
    usage_event(available: false, age_seconds: 400)

    refute Autodev::UsageGate.available?(config: { 'poll_interval' => 60 })
  end

  test 'a long poll interval widens the ttl' do
    usage_event(available: false, age_seconds: 1_500)

    refute Autodev::UsageGate.available?(config: { 'poll_interval' => 900 })
  end

  test 'available? fails open on an unparseable payload' do
    ActivityEvent.create!(issue_id: nil, kind: 'usage', level: 'warn', payload_json: 'not json')

    assert_predicate self, :available?
  end

  test 'state exposes the verdict and the probe time for the dashboard' do
    event = usage_event(available: false)
    state = gate_state

    refute state[:available]
    assert_in_delta event.created_at.to_f, state[:checked_at].to_f, 1
  end

  test 'state reports a nil checked_at when nothing was ever probed' do
    state = gate_state

    assert state[:available]
    assert_nil state[:checked_at]
  end

  # Heartbeats are not usage probes: a `poller` event must never be mistaken
  # for the gate's state.
  test 'a poller heartbeat is not read as usage state' do
    ActivityEvent.create!(issue_id: nil, kind: 'poller', level: 'warn',
                          payload_json: JSON.generate(event: 'cycle_complete', usage_ok: false))

    assert_predicate self, :available?
  end
end

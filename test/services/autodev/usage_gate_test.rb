# frozen_string_literal: true

require_relative '../../rails_helper'

# `UsageChecker` used to be stubbed here, guarded by `unless defined?`, because
# AUTODEV_SKIP_LEGACY kept `lib/autodev` out of the AR test world. Since Autodev
# #64 the tree is required at boot, so the guard was false and the stand-in never
# installed; the gate's only call is stubbed below — `.new(logger:).verdict`
# since Autodev #108 replaced the boolean `#available?` with a typed verdict.

# Autodev::UsageGate — the shared Claude-quota state (Autodev #46), widened by
# Autodev #108 to record which of the probe's six verdicts fired, not only
# whether the gate should be open.
#
# The poll cycle probes once and persists the verdict; every consumer
# (PollDispatcher, PipelineMonitor, IssueProcessJob, the dashboard) reads that
# persisted state instead of shelling out to danger-claude itself.
# rubocop:disable Metrics/ClassLength -- one file per behaviour: probe!, available?/state,
# and the Autodev #108 verdict fields (status/diagnostic) each need their own coverage,
# same call as HealthReportTest and MrReviewTokenProbeTest.
class UsageGateTest < ActiveSupport::TestCase
  CONFIG = { 'poll_interval' => 300 }.freeze

  def stub_checker(verdict, &)
    resolver = verdict.respond_to?(:call) ? verdict : ->(*) { verdict }
    checker = Object.new
    checker.define_singleton_method(:verdict) { instance_exec(&resolver) }
    UsageChecker.stub(:new, checker, &)
  end

  def usage_event(available:, status: nil, diagnostic: nil, age_seconds: 0)
    status ||= available ? 'available' : 'quota_exhausted'
    payload = { available: available, status: status }
    payload[:diagnostic] = diagnostic if diagnostic
    ActivityEvent.create!(
      issue_id: nil, kind: 'usage', level: available ? 'info' : 'warn',
      payload_json: JSON.generate(payload),
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

  def probed_event(verdict)
    stub_checker(verdict) { Autodev::UsageGate.probe!(logger: Logger.new(IO::NULL)) }
    ActivityEvent.where(kind: 'usage').order(:id).last
  end

  test 'probe! persists the verdict as a system usage event' do
    event = probed_event({ status: :quota_exhausted, diagnostic: nil })

    assert_nil event.issue_id
    refute event.payload['available']
  end

  test 'probe! records the status alongside the boolean' do
    event = probed_event({ status: :auth_refused, diagnostic: nil })

    assert_equal 'auth_refused', event.payload['status']
  end

  test 'probe! records the diagnostic only for a broken verdict' do
    event = probed_event({ status: :broken, diagnostic: 'unexpected failure xyz' })

    assert_equal 'unexpected failure xyz', event.payload['diagnostic']
  end

  test 'probe! records no diagnostic key for a recognised cause' do
    event = probed_event({ status: :quota_exhausted, diagnostic: nil })

    refute event.payload.key?('diagnostic')
  end

  test 'probe! records the exhausted verdict at warn level' do
    assert_equal 'warn', probed_event({ status: :quota_exhausted, diagnostic: nil }).level
  end

  test 'probe! returns the gate boolean for each closed status' do
    %i[quota_exhausted auth_refused binary_missing broken].each do |status|
      stub_checker({ status: status, diagnostic: nil }) do
        refute Autodev::UsageGate.probe!(logger: Logger.new(IO::NULL)), "expected #{status} to close the gate"
      end
    end
  end

  test 'probe! returns true for available and for unknown' do
    %i[available unknown].each do |status|
      stub_checker({ status: status, diagnostic: nil }) do
        assert Autodev::UsageGate.probe!(logger: Logger.new(IO::NULL)), "expected #{status} to leave the gate open"
      end
    end
  end

  test 'probe! records level info when the quota is available' do
    assert_equal 'info', probed_event({ status: :available, diagnostic: nil }).level
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

  test 'state exposes the recorded status as a symbol' do
    usage_event(available: false, status: 'auth_refused')

    assert_equal :auth_refused, gate_state[:status]
  end

  test 'state exposes the recorded diagnostic for a broken verdict' do
    usage_event(available: false, status: 'broken', diagnostic: 'boom')

    assert_equal 'boom', gate_state[:diagnostic]
  end

  test 'state reports a nil checked_at when nothing was ever probed' do
    state = gate_state

    assert state[:available]
    assert_nil state[:checked_at]
    assert_nil state[:status]
  end

  # A verdict recorded before Autodev #108 (no `status` key in its payload)
  # must not crash the reader — it just reads less specific than a fresh one.
  test 'a pre-upgrade row with no status key still reads' do
    ActivityEvent.create!(issue_id: nil, kind: 'usage', level: 'warn',
                          payload_json: JSON.generate(available: false))
    state = gate_state

    refute state[:available]
    assert_nil state[:status]
    assert_nil state[:diagnostic]
  end

  # Heartbeats are not usage probes: a `poller` event must never be mistaken
  # for the gate's state.
  test 'a poller heartbeat is not read as usage state' do
    ActivityEvent.create!(issue_id: nil, kind: 'poller', level: 'warn',
                          payload_json: JSON.generate(event: 'cycle_complete', usage_ok: false))

    assert_predicate self, :available?
  end
end
# rubocop:enable Metrics/ClassLength

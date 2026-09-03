# frozen_string_literal: true

require_relative '../rails_helper'

# `Config` and `UsageChecker` used to be stubbed here, guarded by
# `unless defined?`, because AUTODEV_SKIP_LEGACY kept `lib/autodev` out of the AR
# test world. Since Autodev #64 the tree is required at boot, so both guards were
# false and the stubs never installed — the tests below already ran against the
# real constants, stubbing the two calls they make.

# Wiring test for AutodevPollJob. The job's contract is intentionally thin
# (load config → probe the Claude quota → instantiate one PollDispatcher per
# project), so we stub both helpers and just assert the orchestration.
#
# Since Autodev #46 an exhausted quota no longer short-circuits the cycle: the
# verdict is forwarded to each dispatcher, which gates only the passes that
# reach danger-claude.
class AutodevPollJobTest < ActiveSupport::TestCase # rubocop:disable Metrics/ClassLength
  setup do
    @stub_config = {
      'projects' => [
        { 'path' => 'group/foo' },
        { 'path' => 'group/bar' }
      ]
    }
  end

  test 'iterates every project and invokes the dispatcher' do
    dispatched = run_with_stubs(usage_available: true)

    assert_equal %w[group/foo group/bar], dispatched
  end

  test 'discovers projects from the DB even when the YAML projects block is absent' do
    Project.create!(gitlab_path: 'db/only', slug: 'db__only')
    dispatched = []
    fake_dispatcher = build_fake_dispatcher(dispatched)

    Config.stub(:load, {}) do # no 'projects' key in the YAML
      UsageChecker.stub(:new, build_fake_checker(true)) do
        Autodev::PollDispatcher.stub(:new, fake_dispatcher) { AutodevPollJob.new.perform }
      end
    end

    assert_equal ['db/only'], dispatched
  end

  # Autodev #46: the cycle used to return here, freezing pipeline tracking and
  # GitLab-closure detection for the whole outage.
  test 'still runs the cycle when usage is paused' do
    dispatched = run_with_stubs(usage_available: false)

    assert_equal %w[group/foo group/bar], dispatched
  end

  test 'forwards the quota verdict to every dispatcher' do
    verdicts = []
    run_with_stubs(usage_available: false, usage_captures: verdicts)

    assert_equal [false, false], verdicts
  end

  test 'forwards an available quota as true' do
    verdicts = []
    run_with_stubs(usage_available: true, usage_captures: verdicts)

    assert_equal [true, true], verdicts
  end

  test 'persists the quota verdict so the workers and the dashboard can read it' do
    run_with_stubs(usage_available: false)

    refute Autodev::UsageGate.available?(config: {})
  end

  test 'treats a usage-checker crash as available (fail-open)' do
    dispatched = run_with_stubs(usage_available: ->(*) { raise StandardError, 'boom' })

    assert_equal %w[group/foo group/bar], dispatched
  end

  test 'records a poller heartbeat (issue_id nil, usage_ok true) on a successful cycle' do
    run_with_stubs(usage_available: true)

    event = ActivityEvent.where(kind: 'poller').order(:id).last

    assert event, 'expected a poller heartbeat event'
    assert_nil event.issue_id
    assert event.payload['usage_ok']
  end

  test 'records a usage-paused heartbeat with usage_ok false' do
    run_with_stubs(usage_available: false)

    event = ActivityEvent.where(kind: 'poller').order(:id).last

    assert event
    refute event.payload['usage_ok']
    assert_equal 'warn', event.level
  end

  # The old paused heartbeat reported `projects: 0` because nothing ran. It now
  # reports the projects it actually swept, so the health page can tell a paused
  # cycle from a dead one.
  test 'a usage-paused heartbeat still reports the projects it swept' do
    run_with_stubs(usage_available: false)

    assert_equal 2, ActivityEvent.where(kind: 'poller').order(:id).last.payload['projects']
  end

  # Autodev #81: the review-skill check is a per-cycle probe like the quota one,
  # for the same reason — the reader (HealthReport) is passive by contract, so
  # the cycle is what runs the live read and records the verdict. Once per cycle,
  # over the same project list the dispatchers get.
  test 'probes the declared review skills once per cycle, over the cycle projects' do
    calls = []
    probe = ->(config:, projects:, logger: nil) { (calls << [config, projects, logger]) && [] }

    Autodev::ReviewSkillProbe.stub(:probe!, probe) { run_with_stubs(usage_available: true) }

    assert_equal 1, calls.size
    assert_equal(%w[group/foo group/bar], calls.first[1].map { |project| project['path'] })
  end

  # An advisory check must never be the thing that stops a poll cycle — the same
  # ruling `bin/autodev`'s `warn_rejected_numeric_settings` carries.
  test 'a review-skill probe failure does not break the cycle' do
    probe = ->(**) { raise StandardError, 'gitlab down' }

    dispatched = Autodev::ReviewSkillProbe.stub(:probe!, probe) do
      run_with_stubs(usage_available: true)
    end

    assert_equal %w[group/foo group/bar], dispatched
  end

  test 'records a cycle error and re-raises when the cycle blows up' do
    fake_checker = build_fake_checker(true)
    assert_raises(StandardError) do
      Config.stub(:load, ->(*) { raise StandardError, 'boom' }) do
        UsageChecker.stub(:new, fake_checker) do
          AutodevPollJob.new.perform
        end
      end
    end

    event = ActivityEvent.where(kind: 'error').order(:id).last

    assert event, 'expected a cycle-failure event'
    assert_equal [nil, 'error'], [event.issue_id, event.level]
  end

  private

  def run_with_stubs(usage_available:, usage_captures: []) # rubocop:disable Metrics/MethodLength
    dispatched = []
    fake_checker = build_fake_checker(usage_available)
    fake_dispatcher = build_fake_dispatcher(dispatched, usage_captures)

    Config.stub(:load, @stub_config) do
      UsageChecker.stub(:new, fake_checker) do
        Autodev::PollDispatcher.stub(:new, fake_dispatcher) do
          AutodevPollJob.new.perform
        end
      end
    end
    dispatched
  end

  # `available:` is a boolean (or a proc) rather than a full verdict hash — the
  # tests in this file exercise orchestration (which project got dispatched,
  # what the heartbeat says), not the verdict vocabulary itself, so the fake
  # answers the two statuses that matter here: `available` / `quota_exhausted`.
  # `UsageChecker#verdict` replaced `#available?` in Autodev #108.
  def build_fake_checker(available)
    Object.new.tap do |obj|
      block = available.respond_to?(:call) ? available : ->(*) { available }
      obj.define_singleton_method(:verdict) do
        ok = instance_exec(&block)
        { status: ok ? :available : :quota_exhausted, diagnostic: nil }
      end
    end
  end

  def build_fake_dispatcher(captures, usage_captures = [])
    lambda do |config:, project_config:, logger:, usage_ok: true|
      _ = config
      _ = logger
      usage_captures << usage_ok
      Object.new.tap do |obj|
        obj.define_singleton_method(:dispatch) { captures << project_config['path'] }
      end
    end
  end
end

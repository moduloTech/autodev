# frozen_string_literal: true

require_relative '../rails_helper'

# AUTODEV_SKIP_LEGACY=1 (set in rails_helper) prevents the legacy_sinatra
# initializer from loading lib/autodev — and we deliberately don't load it
# here either, because that would pull in pastel/sequel/etc. and collide
# with `test/stub_autodev.rb`'s constants when rake test runs both halves
# of the suite in one process. We define the bare minimum stubs the job
# touches at the top-level so `Config.stub(...)` / `UsageChecker.stub(...)`
# resolve.
Object.const_set(:Config, Module.new { def self.load(*) = {} }) unless defined?(Config)
Object.const_set(:UsageChecker, Class.new { def self.new(**); end }) unless defined?(UsageChecker)

# Wiring test for AutodevPollJob. The job's contract is intentionally thin
# (load config → bail on usage gate → instantiate one PollDispatcher per
# project), so we stub both helpers and just assert the orchestration.
class AutodevPollJobTest < ActiveSupport::TestCase
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

  test 'short-circuits the cycle when usage is paused' do
    dispatched = run_with_stubs(usage_available: false)

    assert_empty dispatched, 'expected no dispatcher call when usage is paused'
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

  def run_with_stubs(usage_available:) # rubocop:disable Metrics/MethodLength
    dispatched = []
    fake_checker = build_fake_checker(usage_available)
    fake_dispatcher = build_fake_dispatcher(dispatched)

    Config.stub(:load, @stub_config) do
      UsageChecker.stub(:new, fake_checker) do
        Autodev::PollDispatcher.stub(:new, fake_dispatcher) do
          AutodevPollJob.new.perform
        end
      end
    end
    dispatched
  end

  def build_fake_checker(available)
    Object.new.tap do |obj|
      block = available.respond_to?(:call) ? available : ->(*) { available }
      obj.define_singleton_method(:available?) { instance_exec(&block) }
    end
  end

  def build_fake_dispatcher(captures)
    lambda do |config:, project_config:, logger:|
      _ = config
      _ = logger
      Object.new.tap do |obj|
        obj.define_singleton_method(:dispatch) { captures << project_config['path'] }
      end
    end
  end
end

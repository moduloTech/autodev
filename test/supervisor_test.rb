# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/supervisor'

# Unit-level test for Autodev::Supervisor. The class shells out to
# `Process.spawn`/`Process.wait2`/`Process.kill` in production; the tests
# inject a fake spawner so we can exercise the lifecycle without forking
# real subprocesses.
class SupervisorTest < Minitest::Test
  # Captures every Process.spawn invocation and returns sequential fake PIDs.
  class StubSpawner
    attr_reader :spawned

    def initialize(start_pid: 90_001)
      @next_pid = start_pid
      @spawned = []
    end

    def call(env, command)
      pid = @next_pid
      @next_pid += 1
      @spawned << { env: env, command: command, pid: pid }
      pid
    end
  end

  # Drop-in replacement for Logger so we can assert on emissions without a
  # real file handle.
  class FakeLogger
    attr_reader :entries

    def initialize
      @entries = []
    end

    %i[info warn error debug].each do |level|
      define_method(level) { |msg, **_| @entries << [level, msg] }
    end
  end

  def setup
    @spawner = StubSpawner.new
    @logger  = FakeLogger.new
  end

  def test_spawn_all_creates_one_child_per_spec
    children = [build_child('web'), build_child('queue')]
    supervisor = build_supervisor(children) { |s| s.instance_variable_set(:@shutdown, true) }

    silence_process_apis { supervisor.run }

    assert_equal 2, @spawner.spawned.size
    assert_equal(%w[web queue], @spawner.spawned.map { |s| s[:command].first })
  end

  def test_env_and_command_are_forwarded_verbatim
    spec = build_child('one', env: { 'A' => '1', 'B' => '2' }, command: %w[one --flag value])
    supervisor = build_supervisor([spec]) { |s| s.instance_variable_set(:@shutdown, true) }

    silence_process_apis { supervisor.run }

    assert_equal({ 'A' => '1', 'B' => '2' }, @spawner.spawned.first[:env])
    assert_equal(%w[one --flag value], @spawner.spawned.first[:command])
  end

  def test_returns_after_shutdown_flag_flips
    supervisor = build_supervisor([build_child('only')]) { |s| s.instance_variable_set(:@shutdown, true) }

    silence_process_apis { supervisor.run }
    # If we got here without blocking, the loop honoured the flag.
    assert_equal 1, @spawner.spawned.size
  end

  def test_logs_an_info_line_per_spawned_child # rubocop:disable Metrics/AbcSize
    children = [build_child('alpha'), build_child('bravo')]
    supervisor = build_supervisor(children) { |s| s.instance_variable_set(:@shutdown, true) }

    silence_process_apis { supervisor.run }

    spawn_lines = @logger.entries.select { |level, msg| level == :info && msg.include?('spawned') }

    assert_equal 2, spawn_lines.size
    assert(spawn_lines.any? { |_, msg| msg.include?('alpha') })
    assert(spawn_lines.any? { |_, msg| msg.include?('bravo') })
  end

  def test_child_alive_returns_false_when_pid_is_nil
    child = Autodev::Supervisor::Child.new(name: 'unspawned', command: %w[x], env: {})

    refute_predicate child, :alive?
  end

  private

  def build_child(name, command: nil, env: {})
    Autodev::Supervisor::Child.new(name: name, command: command || [name], env: env)
  end

  # Build a Supervisor with the fake spawner + a sleeper that immediately
  # yields to the block (so the wait loop runs exactly one tick and then
  # the block sets @shutdown = true). Late-binds the supervisor reference
  # so the sleeper closure can flip @shutdown on the instance it belongs to.
  def build_supervisor(children, &block)
    holder = []
    sleeper = lambda do |_|
      block&.call(holder.first)
    end
    holder << Autodev::Supervisor.new(
      children: children, logger: @logger, spawner: @spawner, sleeper: sleeper
    )
    holder.first
  end

  # Process.wait2 / Process.kill would otherwise raise Errno::ECHILD on the
  # fake PIDs (no actual child to reap / signal). Stub them so Process.kill
  # raises ESRCH ("no such process") for any probe — Child#alive? swallows
  # that and reports the fake child as dead, which lets the graceful
  # shutdown loop return immediately instead of waiting out its 10s grace.
  def silence_process_apis(&)
    no_such_proc = ->(*_) { raise Errno::ESRCH }
    Process.stub(:wait2, nil) do
      Process.stub(:kill, no_such_proc, &)
    end
  end
end

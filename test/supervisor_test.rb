# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/supervisor'

# Unit-level test for Autodev::Supervisor. The class shells out to
# `Process.spawn`/`Process.wait2`/`Process.kill` in production; the tests
# inject a fake spawner so we can exercise the lifecycle without forking
# real subprocesses.
class SupervisorTest < Minitest::Test # rubocop:disable Metrics/ClassLength -- Autodev #92 added the ensure regression suite
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

  def test_clean_child_exit_does_not_shut_down_peers
    child = build_child('queue')
    child.pid = 90_500
    supervisor = build_supervisor([child])

    supervisor.send(:handle_child_exit, 90_500, fake_status(0))

    refute supervisor.instance_variable_get(:@shutdown), 'a clean exit must not tear peers down'
    assert_nil child.pid
  end

  def test_crashing_child_shuts_down_peers
    child = build_child('queue')
    child.pid = 90_500
    supervisor = build_supervisor([child])

    supervisor.send(:handle_child_exit, 90_500, fake_status(1))

    assert supervisor.instance_variable_get(:@shutdown), 'a non-zero exit tears peers down'
  end

  # === Autodev #92: `run` must take its children with it on any abrupt end ===
  # There is no `ensure` around `shutdown_children` yet — these are written
  # first and are red until lib/autodev/supervisor.rb#run gets one.

  def test_spawn_all_raising_on_the_second_child_terms_the_first # rubocop:disable Metrics/MethodLength
    spawner = lambda do |_env, command|
      raise 'boom: second spawn failed' if command.first == 'solid-queue'

      90_001
    end
    children = [build_child('rails-server'), build_child('solid-queue')]
    supervisor = Autodev::Supervisor.new(children: children, logger: @logger, spawner: spawner, sleeper: ->(_) {})
    killed = []

    with_fake_kill(alive: Hash.new(true), killed: killed) do
      assert_raises(RuntimeError) { supervisor.run }
    end

    assert_includes killed, ['TERM', 90_001], 'the already-spawned first child must be TERMed'
  end

  def test_wait_loop_raising_terms_every_already_spawned_child # rubocop:disable Metrics/AbcSize,Metrics/MethodLength
    boom = Class.new(StandardError)
    children = [build_child('rails-server'), build_child('solid-queue')]
    sleeper = ->(_) { raise boom, 'kaboom mid-wait' }
    supervisor = Autodev::Supervisor.new(children: children, logger: @logger, spawner: @spawner, sleeper: sleeper)
    killed = []

    with_fake_kill(alive: Hash.new(true), killed: killed) do
      assert_raises(boom) { supervisor.run }
    end

    spawned_pids = @spawner.spawned.map { |s| s[:pid] }

    assert_equal 2, spawned_pids.size
    spawned_pids.each { |pid| assert_includes killed, ['TERM', pid] }
  end

  def test_normal_shutdown_terms_each_child_exactly_once
    children = [build_child('rails-server'), build_child('solid-queue')]
    supervisor = build_supervisor(children) { |s| s.instance_variable_set(:@shutdown, true) }
    killed = []

    with_fake_kill(alive: Hash.new(true), killed: killed) { supervisor.run }

    term_calls = killed.count { |sig, _| sig == 'TERM' }

    assert_equal 2, term_calls, 'each child must be TERMed exactly once — no double shutdown_children'
  end

  def test_shutdown_children_run_twice_in_a_row_is_harmless
    child = build_child('rails-server')
    child.pid = 90_900
    supervisor = build_supervisor([child])
    killed = []

    with_fake_kill(alive: Hash.new(true), killed: killed) do
      supervisor.send(:shutdown_children)
      supervisor.send(:shutdown_children)
    end

    term_calls = killed.count { |sig, pid| sig == 'TERM' && pid == 90_900 }

    assert_equal 1, term_calls, 'a second shutdown_children must not re-TERM an already-dead child'
  end

  def test_child_ignoring_term_is_still_killed_after_the_grace # rubocop:disable Metrics/MethodLength
    child = build_child('rails-server')
    child.pid = 90_777
    supervisor = build_supervisor([child])
    killed = []
    clock_calls = 0
    fast_forward_clock = lambda do |*_|
      clock_calls += 1
      clock_calls == 1 ? 0.0 : 100.0 # first call sets the deadline, second jumps past it
    end

    Process.stub(:clock_gettime, fast_forward_clock) do
      with_fake_kill(alive: { 90_777 => true }, killed: killed, ignored_signals: ['TERM']) do
        supervisor.send(:shutdown_children)
      end
    end

    assert_includes killed, ['TERM', 90_777]
    assert_includes killed, ['KILL', 90_777], 'a straggler past the grace period must still be KILLed'
  end

  private

  def fake_status(code)
    Struct.new(:exitstatus).new(code)
  end

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

  # A richer double than silence_process_apis: tracks every non-probe signal
  # sent (`killed << [sig, pid]`) instead of pretending every pid is already
  # dead, so a test can assert TERM/KILL actually reached a given pid.
  # `alive` maps pid => currently-alive?; a signal in `ignored_signals` (e.g.
  # a straggler that ignores TERM) is recorded but does not flip it to dead.
  def with_fake_kill(alive:, killed: [], ignored_signals: [], &)
    kill = fake_kill(alive: alive, killed: killed, ignored_signals: ignored_signals)
    Process.stub(:kill, kill) do
      Process.stub(:wait2, ->(*_) {}) do
        Process.stub(:wait, ->(*_) {}, &)
      end
    end
  end

  def fake_kill(alive:, killed:, ignored_signals:)
    lambda do |sig, pid|
      # sig is 0 (the liveness probe) or a signal name string ('TERM'/'KILL'),
      # never just a number to call a numeric predicate on.
      if sig == 0 # rubocop:disable Style/NumericPredicate
        raise Errno::ESRCH unless alive[pid]
      else
        killed << [sig, pid]
        alive[pid] = false unless ignored_signals.include?(sig)
      end
      0
    end
  end
end

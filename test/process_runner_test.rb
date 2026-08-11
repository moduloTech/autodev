# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/process_runner'

# resolve_timeout's fallback chain (Autodev #54 final-review fix).
#
# This is the one piece of the mr_review_timeout change with no direct test:
# test/danger_claude_runner_heartbeat_test.rb's Harness stubs run_with_timeout
# itself, and nothing else in the suite reaches resolve_timeout — property 1 of
# the mr-review-timeout design ("the two danger-claude callers keep resolving
# dc_timeout") rested on inspection alone. It protects every implementation
# call in the product, not just mr-review's, so it gets its own pin.
class ProcessRunnerTest < Minitest::Test
  # Bare host carrying only what resolve_timeout reads. No database needed.
  class Harness
    include ProcessRunner

    def initialize(project_config: {}, config: {})
      @project_config = project_config
      @config = config
    end
  end

  def test_an_explicit_timeout_wins
    harness = Harness.new(project_config: { 'dc_timeout' => 1800 }, config: { 'dc_timeout' => 900 })

    assert_equal 60, harness.send(:resolve_timeout, 60)
  end

  def test_a_nil_timeout_falls_through_to_the_project_config
    harness = Harness.new(project_config: { 'dc_timeout' => 1800 }, config: { 'dc_timeout' => 900 })

    assert_equal 1800, harness.send(:resolve_timeout, nil)
  end

  def test_an_absent_project_value_falls_through_to_the_global_config
    harness = Harness.new(project_config: {}, config: { 'dc_timeout' => 900 })

    assert_equal 900, harness.send(:resolve_timeout, nil)
  end

  def test_everything_absent_falls_through_to_the_last_resort
    harness = Harness.new(project_config: {}, config: {})

    assert_equal 600, harness.send(:resolve_timeout, nil)
  end

  # What run_with_timeout hands back (Autodev #49).
  #
  # A real subprocess is the only honest way to pin it, and it doubles as the
  # suite's first direct proof that stdout is captured at all — the premise of
  # #49, whose bug was that the mr-review caller threw stdout away. Keep the
  # number of real spawns here to these two: wait_for_completion polls with
  # `sleep 1`, so each costs up to a second.
  SCRIPT = 'printf hello; printf oops >&2; exit 3'

  def spawn_harness
    harness = Harness.new
    harness.instance_variable_set(:@dc_stdout, +'')
    harness.instance_variable_set(:@dc_stderr, +'')
    harness
  end

  def test_a_failed_run_reports_both_streams_and_the_exit_status
    out, err, _ok, status = spawn_harness.send(:run_with_timeout, '/bin/sh', ['-c', SCRIPT],
                                               chdir: Dir.pwd, timeout: 30)

    assert_equal 'hello', out
    assert_equal 'oops', err
    assert_equal 3, status.exitstatus
  end

  # The compatibility claim the two danger-claude callers rest on: a surplus
  # fourth element must not disturb a three-variable destructuring.
  def test_a_three_element_destructuring_still_binds
    out, err, ok = spawn_harness.send(:run_with_timeout, '/bin/sh', ['-c', SCRIPT],
                                      chdir: Dir.pwd, timeout: 30)

    assert_equal 'hello', out
    assert_equal 'oops', err
    refute ok
  end
end

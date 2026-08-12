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

  # Autodev #59. `record_output` is the *only* writer of @dc_stdout / @dc_stderr,
  # and twelve persistence sites across the four workers copy those two ivars
  # straight into `issues.dc_stdout` / `issues.dc_stderr` — none of them scrubbed.
  # The scrub therefore belongs here rather than at any one call site: a token
  # that never enters the buffer cannot leak out of whichever site persists it.
  #
  # No subprocess needed — `record_output` reads its streams off the two reader
  # threads, so a plain `Thread` carrying the payload exercises the real path
  # without paying `wait_for_completion`'s `sleep 1`.
  TOKEN = 'glpat-Abc123DEF456ghi789'
  PUSH_URL = 'https://oauth2:glpat-Abc123DEF456ghi789@source.example.fr/g/p.git'

  def record(harness, out, err)
    harness.send(:record_output, 'mr-review', nil, Thread.new { out }, Thread.new { err })
  end

  def test_a_bare_gitlab_token_on_stdout_never_reaches_the_diagnostic_buffer
    harness = spawn_harness
    record(harness, "token=#{TOKEN}\n", '')

    buffer = harness.instance_variable_get(:@dc_stdout)

    refute_includes buffer, TOKEN, 'a PAT must not survive into the persisted diagnostic'
    assert_includes buffer, 'token=***'
  end

  def test_credentials_embedded_in_a_url_on_stderr_never_reach_the_diagnostic_buffer
    harness = spawn_harness
    record(harness, '', "fatal: could not read from #{PUSH_URL}\n")

    buffer = harness.instance_variable_get(:@dc_stderr)

    refute_includes buffer, TOKEN
    assert_includes buffer, 'https://oauth2:***@source.example.fr/g/p.git'
  end

  # The scrub is confined to the buffer. What comes back to the caller stays
  # byte-identical, because `capture_session_and_text` JSON-parses stdout and
  # both fatal-signature detectors match on it — rewriting the caller's copy
  # would change how danger-claude output is read, which this ticket is not
  # about (`review_failure_diagnostic` already scrubs its own message).
  def test_the_streams_handed_back_to_the_caller_are_untouched
    out, err = record(spawn_harness, "token=#{TOKEN}\n", "url=#{PUSH_URL}\n")

    assert_equal "token=#{TOKEN}\n", out
    assert_equal "url=#{PUSH_URL}\n", err
  end
end

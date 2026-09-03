# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/usage_checker'

# UsageChecker#verdict — Autodev #108.
#
# `send_probe` used to be an unstubbed `Open3.capture3('danger-claude', …)`, so
# these tests spawn real (cheap) `/bin/sh` subprocesses via the injectable
# `command:` / `timeout:` / `kill_grace:` constructor params instead of faking
# Open3 — the same idiom ProcessRunnerTest uses for run_with_timeout. Nothing
# here talks to a real danger-claude or Claude.
class UsageCheckerTest < Minitest::Test
  class NullLogger
    def info(*, **) = nil
    def warn(*, **) = nil
    def error(*, **) = nil
    def debug(*, **) = nil
  end

  def checker(command:, timeout: 5, kill_grace: 0.2, cache_ttl: UsageChecker::CACHE_TTL)
    UsageChecker.new(logger: NullLogger.new, command: command, timeout: timeout,
                     kill_grace: kill_grace, cache_ttl: cache_ttl)
  end

  def sh(script) = ['/bin/sh', '-c', script]

  # --- the six verdicts ----------------------------------------------------

  def test_exit_zero_is_available
    verdict = checker(command: sh('exit 0')).verdict

    assert_equal :available, verdict[:status]
    assert_nil verdict[:diagnostic]
  end

  def test_a_rate_limit_signature_reads_quota_exhausted
    verdict = checker(command: sh('echo "You have hit your usage limit" >&2; exit 1')).verdict

    assert_equal :quota_exhausted, verdict[:status]
    assert_nil verdict[:diagnostic]
  end

  # The verbatim signature of the 02/09 incident (16:10-16:28).
  def test_a_401_signature_reads_auth_refused
    verdict = checker(command: sh('echo "API error: 401 Invalid authentication credentials"; exit 1')).verdict

    assert_equal :auth_refused, verdict[:status]
    assert_nil verdict[:diagnostic]
  end

  def test_a_missing_binary_reads_binary_missing
    verdict = checker(command: ['/nonexistent/path/danger-claude-xyz']).verdict

    assert_equal :binary_missing, verdict[:status]
    assert_nil verdict[:diagnostic]
  end

  # The verbatim signature of the Docker-engine outage (02/09 23:00-03/09
  # 08:24): a 500 that carries neither a rate-limit nor an auth signature.
  # No Docker-specific pattern is written — this is the whole point of the
  # `broken` bucket (Autodev #108 design, "Where the code goes").
  DOCKER_500 = 'Error response from daemon: request returned 500 Internal Server Error for API route ' \
               'and version .../v1.54/volumes/danger-claude, check if the server supports the ' \
               'requested API version'

  def test_an_unrecognised_non_zero_exit_reads_broken_with_a_diagnostic
    verdict = checker(command: sh(%(echo "#{DOCKER_500}"; exit 1))).verdict

    assert_equal :broken, verdict[:status]
    assert_includes verdict[:diagnostic], 'v1.54/volumes/danger-claude'
  end

  def test_a_timeout_reads_unknown
    verdict = checker(command: sh('sleep 5'), timeout: 0.3).verdict

    assert_equal :unknown, verdict[:status]
    assert_nil verdict[:diagnostic]
  end

  # --- precedence ------------------------------------------------------------

  # Order is fixed (Autodev #108 design §2): quota before auth, so a cycle
  # where both signatures are present keeps reading as the cause that resolves
  # itself.
  def test_a_rate_limit_and_a_401_signature_together_read_quota_exhausted
    script = 'echo "You have hit your usage limit"; echo "API error: 401" >&2; exit 1'
    verdict = checker(command: sh(script)).verdict

    assert_equal :quota_exhausted, verdict[:status]
  end

  # --- the diagnostic is scrubbed and bounded ---------------------------------

  def test_the_diagnostic_is_scrubbed_of_secrets
    script = 'echo "clone failed: https://oauth2:glpat-SECRETVALUE@source.example/g/p.git"; exit 1'
    verdict = checker(command: sh(script)).verdict

    assert_equal :broken, verdict[:status]
    refute_includes verdict[:diagnostic], 'glpat-SECRETVALUE'
  end

  def test_the_diagnostic_is_truncated
    script = "echo #{'x' * (UsageChecker::DIAGNOSTIC_MAX + 500)}; exit 1"
    verdict = checker(command: sh(script)).verdict

    assert_operator verdict[:diagnostic].length, :<=, UsageChecker::DIAGNOSTIC_MAX
  end

  def test_only_broken_carries_a_diagnostic
    refute checker(command: sh('exit 0')).verdict[:diagnostic]
    refute checker(command: sh('echo "usage limit"; exit 1')).verdict[:diagnostic]
    refute checker(command: sh('echo "API error: 401"; exit 1')).verdict[:diagnostic]
  end

  # --- the timeout kills the process group, not just gives up ----------------

  def test_a_timed_out_probe_kills_the_child_process_group
    Dir.mktmpdir do |dir|
      pidfile = File.join(dir, 'child.pid')
      checker(command: sh("echo $$ > #{pidfile}; sleep 5"), timeout: 0.2, kill_grace: 0.2).verdict
      child_pid = Integer(File.read(pidfile).strip)

      assert_raises(Errno::ESRCH) { Process.kill(0, child_pid) }
    end
  end

  # --- caching (unchanged instance-level TTL) ---------------------------------

  def test_a_fresh_verdict_is_reused_within_the_cache_ttl
    calls = 0
    c = checker(command: sh('exit 0'), cache_ttl: 300)
    c.define_singleton_method(:check!) do
      calls += 1
      super()
    end

    2.times { c.verdict }

    assert_equal 1, calls
  end

  def test_an_expired_cache_reprobes
    calls = 0
    c = checker(command: sh('exit 0'), cache_ttl: -1) # always expired
    c.define_singleton_method(:check!) do
      calls += 1
      super()
    end

    2.times { c.verdict }

    assert_equal 2, calls
  end
end

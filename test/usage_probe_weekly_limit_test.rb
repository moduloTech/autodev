# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/usage_checker'

# The usage probe during the weekly limit — Autodev #127.
#
# From 2026-09-27 04:46 every probe classified `broken` (1000+ in a row, the
# `danger_claude` card down, `claude_usage` ok) on a quota. The output below is
# the persisted diagnostic, verbatim: claude's answer, then mise complaining
# about `~/.config/mise/config.toml` — the service account's global config,
# which danger-claude mounted into the container because the probe ran in the
# LaunchAgent's WorkingDirectory, `/Users/modulotech`.
class UsageProbeWeeklyLimitTest < Minitest::Test
  class NullLogger
    def info(*, **) = nil
    def warn(*, **) = nil
    def error(*, **) = nil
    def debug(*, **) = nil
  end

  PROBE_OUTPUT = <<~OUT
    You've hit your weekly limit · resets Oct 1, 3am (UTC)

    mise ERROR error parsing config file: ~/modulotech/.config/mise/config.toml
    mise ERROR Config files in ~/modulotech/.config/mise/config.toml are not trusted.
    Trust them with `mise trust`. See https://mise.en.dev/cli/trust.html for more information.
  OUT

  def checker(command) = UsageChecker.new(logger: NullLogger.new, command: command, timeout: 5, kill_grace: 0.2)

  def test_the_weekly_limit_reads_quota_exhausted
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'out.txt')
      File.write(path, PROBE_OUTPUT)
      verdict = checker(['/bin/sh', '-c', "cat '#{path}'; exit 1"]).verdict

      assert_equal :quota_exhausted, verdict[:status]
    end
  end

  # danger-claude mounts its working directory into the container. The probe
  # asks one word of claude; it has no business mounting the home that holds
  # ~/.autodev/config.yml, nor inheriting whatever mise config sits there.
  def probe_where = checker(['/bin/sh', '-c', 'echo "cwd=$(pwd -P)"; echo "entries=$(ls -A | wc -l)"; exit 1']).verdict

  def test_the_probe_runs_under_tmp_and_not_in_the_process_cwd
    cwd = probe_where[:diagnostic][/cwd=(\S+)/, 1]

    refute_equal File.realpath(Dir.pwd), cwd
    assert cwd.start_with?("#{File.realpath('/tmp')}/"), "#{cwd} is not under /tmp, where real calls run"
  end

  def test_the_probe_directory_is_empty_and_removed_after_the_probe
    diagnostic = probe_where[:diagnostic]
    cwd = diagnostic[/cwd=(\S+)/, 1]

    assert_match(/entries=\s*0\b/, diagnostic)
    refute Dir.exist?(cwd), "the probe directory #{cwd} outlived the probe"
  end

  def test_the_probe_directory_is_removed_after_a_timeout_too
    marker = File.join(Dir.tmpdir, "autodev-probe-cwd-#{Process.pid}")
    UsageChecker.new(logger: NullLogger.new, command: ['/bin/sh', '-c', "pwd -P > '#{marker}'; sleep 5"],
                     timeout: 0.5, kill_grace: 0.2).verdict
    cwd = File.read(marker).strip

    refute Dir.exist?(cwd), "the probe directory #{cwd} outlived a timed-out probe"
  ensure
    FileUtils.rm_f(marker) if marker
  end
end

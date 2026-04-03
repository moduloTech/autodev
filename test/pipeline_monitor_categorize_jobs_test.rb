# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/pipeline_monitor'

class PipelineMonitorCategorizeJobsTest < Minitest::Test
  def setup
    @monitor = PipelineMonitor.allocate
  end

  def test_categorize_jobs_mutates_entries
    entries = [
      { name: 'rspec', stage: 'test', log_path: 'rspec.log' },
      { name: 'rubocop', stage: 'lint', log_path: 'rubocop.log' }
    ]

    @monitor.send(:categorize_jobs!, entries, '/nonexistent')

    assert_equal :test, entries[0][:category]
    assert_equal :lint, entries[1][:category]
  end

  def test_categorize_jobs_with_mixed_categories
    entries = [
      { name: 'build', stage: 'build', log_path: 'build.log' },
      { name: 'deploy staging', stage: 'deploy', log_path: 'deploy.log' },
      { name: 'mystery', stage: 'ci', log_path: 'mystery.log' }
    ]

    @monitor.send(:categorize_jobs!, entries, '/nonexistent')

    assert_equal :build, entries[0][:category]
    assert_equal :deploy, entries[1][:category]
    assert_equal :unknown, entries[2][:category]
  end

  def test_categorize_jobs_empty_entries
    entries = []

    @monitor.send(:categorize_jobs!, entries, '/nonexistent')

    assert_equal [], entries
  end

  def test_categorize_jobs_with_log_based_detection
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'custom.log'), "Running tests...\n3 failures\nFailed examples:\n")
      entries = [{ name: 'custom', stage: 'ci', log_path: 'custom.log' }]

      @monitor.send(:categorize_jobs!, entries, dir)

      assert_equal :test, entries[0][:category]
    end
  end

  def test_categorize_jobs_preserves_other_entry_keys
    entries = [{ name: 'rspec', stage: 'test', log_path: 'rspec.log', extra: 'data' }]

    @monitor.send(:categorize_jobs!, entries, '/nonexistent')

    assert_equal 'data', entries[0][:extra]
    assert_equal :test, entries[0][:category]
  end
end

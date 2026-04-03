# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/pipeline_monitor'

class PipelineMonitorCategorizeTest < Minitest::Test
  def setup
    @monitor = PipelineMonitor.allocate
  end

  def test_categorize_test_by_name
    entry = { name: 'rspec', stage: 'check', log_path: 'x.log' }

    assert_equal :test, @monitor.send(:categorize_job, entry, '/nonexistent')
  end

  def test_categorize_lint_by_name
    entry = { name: 'rubocop', stage: 'check', log_path: 'x.log' }

    assert_equal :lint, @monitor.send(:categorize_job, entry, '/nonexistent')
  end

  def test_categorize_build_by_name
    entry = { name: 'build', stage: 'check', log_path: 'x.log' }

    assert_equal :build, @monitor.send(:categorize_job, entry, '/nonexistent')
  end

  def test_categorize_deploy_by_name
    entry = { name: 'deploy staging', stage: 'run', log_path: 'x.log' }

    assert_equal :deploy, @monitor.send(:categorize_job, entry, '/nonexistent')
  end

  def test_categorize_by_stage
    entry = { name: 'run_checks', stage: 'test', log_path: 'x.log' }

    assert_equal :test, @monitor.send(:categorize_job, entry, '/nonexistent')
  end

  def test_categorize_by_log_content
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'job.log'), "Running tests...\n3 failures, 2 errors\nFailed examples:\n")
      entry = { name: 'custom_job', stage: 'ci', log_path: 'job.log' }

      assert_equal :test, @monitor.send(:categorize_job, entry, dir)
    end
  end

  def test_categorize_lint_by_log_content
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'job.log'), "Inspecting 42 files\n5 offenses detected\n")
      entry = { name: 'quality', stage: 'ci', log_path: 'job.log' }

      assert_equal :lint, @monitor.send(:categorize_job, entry, dir)
    end
  end

  def test_categorize_build_by_log_content
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, 'job.log'), "Compiling...\nsyntax error, unexpected end-of-input\n")
      entry = { name: 'ci_step', stage: 'ci', log_path: 'job.log' }

      assert_equal :build, @monitor.send(:categorize_job, entry, dir)
    end
  end

  def test_categorize_unknown_when_no_match
    entry = { name: 'mystery', stage: 'ci', log_path: 'missing.log' }

    assert_equal :unknown, @monitor.send(:categorize_job, entry, '/nonexistent')
  end

  def test_categorize_unknown_when_log_file_missing
    Dir.mktmpdir do |dir|
      entry = { name: 'mystery', stage: 'ci', log_path: 'nonexistent.log' }

      assert_equal :unknown, @monitor.send(:categorize_job, entry, dir)
    end
  end
end

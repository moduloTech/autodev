# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/pipeline_monitor'

class PipelineMonitorPreTriageTest < Minitest::Test
  FakeJob = Struct.new(:failure_reason, :name, :stage)
  def setup
    @monitor = PipelineMonitor.allocate
  end

  # -- pre_triage --

  def test_all_infra_reasons_returns_infra
    jobs = [
      FakeJob.new(failure_reason: 'runner_system_failure', name: 'build', stage: 'build'),
      FakeJob.new(failure_reason: 'stuck_or_timeout_failure', name: 'test', stage: 'test')
    ]
    result = @monitor.send(:pre_triage, jobs)

    assert_equal :infra, result[:verdict]
  end

  def test_all_script_failure_all_deploy_returns_infra
    jobs = [
      FakeJob.new(failure_reason: 'script_failure', name: 'deploy_staging', stage: 'deploy'),
      FakeJob.new(failure_reason: 'script_failure', name: 'deploy_production', stage: 'deploy')
    ]
    result = @monitor.send(:pre_triage, jobs)

    assert_equal :infra, result[:verdict]
  end

  def test_all_script_failure_no_deploy_returns_code
    jobs = [
      FakeJob.new(failure_reason: 'script_failure', name: 'rspec', stage: 'test'),
      FakeJob.new(failure_reason: 'script_failure', name: 'rubocop', stage: 'lint')
    ]
    result = @monitor.send(:pre_triage, jobs)

    assert_equal :code, result[:verdict]
  end

  def test_all_script_failure_mixed_deploy_returns_code
    jobs = [
      FakeJob.new(failure_reason: 'script_failure', name: 'rspec', stage: 'test'),
      FakeJob.new(failure_reason: 'script_failure', name: 'deploy_staging', stage: 'deploy')
    ]
    result = @monitor.send(:pre_triage, jobs)

    assert_equal :code, result[:verdict]
  end

  def test_mixed_reasons_returns_uncertain
    jobs = [
      FakeJob.new(failure_reason: 'script_failure', name: 'rspec', stage: 'test'),
      FakeJob.new(failure_reason: 'runner_system_failure', name: 'build', stage: 'build')
    ]
    result = @monitor.send(:pre_triage, jobs)

    assert_equal :uncertain, result[:verdict]
  end

  def test_unknown_reasons_returns_uncertain
    jobs = [
      FakeJob.new(failure_reason: 'unknown_reason', name: 'job1', stage: 'test')
    ]
    result = @monitor.send(:pre_triage, jobs)

    assert_equal :uncertain, result[:verdict]
  end

  def test_nil_failure_reason_returns_uncertain
    jobs = [
      FakeJob.new(failure_reason: nil, name: 'job1', stage: 'test')
    ]
    result = @monitor.send(:pre_triage, jobs)

    assert_equal :uncertain, result[:verdict]
  end

  def test_hash_style_jobs
    jobs = [
      { 'failure_reason' => 'script_failure', 'name' => 'rspec', 'stage' => 'test' }
    ]
    result = @monitor.send(:pre_triage, jobs)

    assert_equal :code, result[:verdict]
  end

  def test_deploy_detected_by_stage
    jobs = [
      FakeJob.new(failure_reason: 'script_failure', name: 'run_job', stage: 'production')
    ]
    result = @monitor.send(:pre_triage, jobs)

    assert_equal :infra, result[:verdict]
  end

  # -- categorize_job --

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
      log_path = File.join(dir, 'job.log')
      File.write(log_path, "Running tests...\n3 failures, 2 errors\nFailed examples:\n")
      entry = { name: 'custom_job', stage: 'ci', log_path: 'job.log' }

      assert_equal :test, @monitor.send(:categorize_job, entry, dir)
    end
  end

  def test_categorize_lint_by_log_content
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, 'job.log')
      File.write(log_path, "Inspecting 42 files\n5 offenses detected\n")
      entry = { name: 'quality', stage: 'ci', log_path: 'job.log' }

      assert_equal :lint, @monitor.send(:categorize_job, entry, dir)
    end
  end

  def test_categorize_build_by_log_content
    Dir.mktmpdir do |dir|
      log_path = File.join(dir, 'job.log')
      File.write(log_path, "Compiling...\nsyntax error, unexpected end-of-input\n")
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

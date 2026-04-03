# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/pipeline_monitor'

class PipelineMonitorWriteJobLogsTest < Minitest::Test
  FakeJob = Struct.new(:id, :name, :stage)

  def setup
    @monitor = PipelineMonitor.allocate
    traces = {}
    @traces = traces
    @monitor.define_singleton_method(:fetch_job_trace) { |job| traces[job] }
  end

  def test_writes_log_files_for_first_job
    Dir.mktmpdir do |log_dir|
      job = FakeJob.new(1, 'rspec', 'test')
      @traces[job] = "test output line 1\ntest output line 2"

      entries = @monitor.send(:write_job_logs, [job], log_dir)

      assert_equal 'rspec', entries[0][:name]
      assert_equal 'test', entries[0][:stage]
      assert_equal 'tmp/ci_logs/rspec.log', entries[0][:log_path]
    end
  end

  def test_writes_correct_file_content
    Dir.mktmpdir do |log_dir|
      job = FakeJob.new(1, 'rspec', 'test')
      @traces[job] = "test output line 1\ntest output line 2"

      @monitor.send(:write_job_logs, [job], log_dir)

      assert_equal "test output line 1\ntest output line 2", File.read(File.join(log_dir, 'rspec.log'))
    end
  end

  def test_writes_multiple_jobs
    Dir.mktmpdir do |log_dir|
      job1 = FakeJob.new(1, 'rspec', 'test')
      job2 = FakeJob.new(2, 'rubocop', 'lint')
      @traces[job1] = 'test output'
      @traces[job2] = 'lint output'

      entries = @monitor.send(:write_job_logs, [job1, job2], log_dir)

      assert_equal 2, entries.size
      assert_equal 'lint output', File.read(File.join(log_dir, 'rubocop.log'))
    end
  end

  def test_sanitizes_filenames
    Dir.mktmpdir do |log_dir|
      job = FakeJob.new(3, 'build/assets [dev]', 'build')
      @traces[job] = 'build log'
      expected_filename = 'build_assets__dev_.log'

      entries = @monitor.send(:write_job_logs, [job], log_dir)

      assert_equal "tmp/ci_logs/#{expected_filename}", entries[0][:log_path]
      assert_path_exists File.join(log_dir, expected_filename)
    end
  end

  def test_empty_jobs_returns_empty_array
    Dir.mktmpdir do |log_dir|
      entries = @monitor.send(:write_job_logs, [], log_dir)

      assert_equal [], entries
    end
  end

  def test_hash_style_jobs
    Dir.mktmpdir do |log_dir|
      job = { 'id' => 10, 'name' => 'jest', 'stage' => 'test' }
      @traces[job] = 'jest output'

      entries = @monitor.send(:write_job_logs, [job], log_dir)

      assert_equal 'jest', entries[0][:name]
      assert_equal 'test', entries[0][:stage]
    end
  end
end

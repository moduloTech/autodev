# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/pipeline_monitor'

class PipelineMonitorBuildEvalContextTest < Minitest::Test
  def setup
    @monitor = PipelineMonitor.allocate
  end

  def test_single_job_entry
    entries = [{ name: 'rspec', stage: 'test', log_path: 'tmp/ci_logs/rspec.log' }]
    result = @monitor.send(:build_eval_context, entries)

    assert_equal '- **rspec** (stage: test) — log complet : `tmp/ci_logs/rspec.log`', result
  end

  def test_multiple_job_entries
    entries = [
      { name: 'rspec', stage: 'test', log_path: 'tmp/ci_logs/rspec.log' },
      { name: 'rubocop', stage: 'lint', log_path: 'tmp/ci_logs/rubocop.log' }
    ]
    result = @monitor.send(:build_eval_context, entries)
    lines = result.split("\n")

    assert_equal 2, lines.size
    assert_includes lines[0], '**rspec**'
    assert_includes lines[1], '**rubocop**'
  end

  def test_empty_entries
    result = @monitor.send(:build_eval_context, [])

    assert_equal '', result
  end

  def test_output_contains_stage_and_log_path
    entries = [{ name: 'jest', stage: 'frontend_test', log_path: 'tmp/ci_logs/jest.log' }]
    result = @monitor.send(:build_eval_context, entries)

    assert_includes result, 'stage: frontend_test'
    assert_includes result, '`tmp/ci_logs/jest.log`'
  end
end

# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require 'autodev/danger_claude_runner'
require 'autodev/pipeline_monitor'

# task #9 phase 2: the per-project `stagnation_threshold` override now actually
# applies at runtime. It used to read only the global `@config` value, so a
# project that set its own threshold in config was silently ignored.
class PipelineMonitorStagnationThresholdTest < Minitest::Test
  FakeIssue = Struct.new(:stagnation_signatures)

  def monitor(project_config: {}, config: {})
    PipelineMonitor.allocate.tap do |m|
      m.instance_variable_set(:@project_config, project_config)
      m.instance_variable_set(:@config, config)
    end
  end

  def test_prefers_project_override_over_global
    m = monitor(project_config: { 'stagnation_threshold' => 2 }, config: { 'stagnation_threshold' => 5 })

    assert_equal 2, m.send(:stagnation_threshold)
  end

  def test_falls_back_to_global_then_baked_default
    assert_equal 5, monitor(config: { 'stagnation_threshold' => 5 }).send(:stagnation_threshold)
    assert_equal 5, monitor.send(:stagnation_threshold)
  end

  def test_stagnated_honors_the_project_threshold
    issue = FakeIssue.new(JSON.generate('pipeline' => { 'signature' => 'abc', 'count' => 2 }))
    m = monitor(project_config: { 'stagnation_threshold' => 2 }, config: { 'stagnation_threshold' => 5 })

    assert m.send(:stagnated?, issue, :pipeline, 'abc')
  end
end

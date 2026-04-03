# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/pipeline_monitor'

class PipelineMonitorPipelineIdTest < Minitest::Test
  FakePipeline = Struct.new(:id)

  def setup
    @monitor = PipelineMonitor.allocate
  end

  def test_pipeline_id_with_object
    pipeline = FakePipeline.new(42)

    assert_equal 42, @monitor.send(:pipeline_id, pipeline)
  end

  def test_pipeline_id_with_hash
    pipeline = { 'id' => 99 }

    assert_equal 99, @monitor.send(:pipeline_id, pipeline)
  end

  def test_pipeline_id_with_struct
    pipeline = FakePipeline.new(7)

    assert_equal 7, @monitor.send(:pipeline_id, pipeline)
  end

  def test_pipeline_id_with_large_id
    pipeline = FakePipeline.new(123_456_789)

    assert_equal 123_456_789, @monitor.send(:pipeline_id, pipeline)
  end
end

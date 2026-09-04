# frozen_string_literal: true

require_relative 'test_helper'

# Autodev #110: the dispatcher reserves the row and therefore needs the backoff
# the monitor used to own alone. Two copies of one lookup is how two answers
# drift apart, so both read Config.
class InfraRecheckSettingsTest < Minitest::Test
  def test_the_project_value_wins_over_the_global_one
    assert_equal 7, ::Config.infra_recheck_max({ 'infra_recheck_max' => 7 },
                                               { 'infra_recheck_max' => 3 })
    assert_equal 90, ::Config.infra_recheck_backoff({ 'infra_recheck_backoff' => 90 },
                                                    { 'infra_recheck_backoff' => 30 })
  end

  def test_the_global_value_is_used_when_the_project_says_nothing
    assert_equal 3, ::Config.infra_recheck_max({}, { 'infra_recheck_max' => 3 })
    assert_equal 30, ::Config.infra_recheck_backoff({}, { 'infra_recheck_backoff' => 30 })
  end

  def test_the_baked_defaults_are_the_pipeline_monitors
    assert_equal ::PipelineMonitor::DEFAULT_INFRA_RECHECK_MAX, ::Config.infra_recheck_max({}, {})
    assert_equal ::PipelineMonitor::DEFAULT_INFRA_RECHECK_BACKOFF, ::Config.infra_recheck_backoff({}, {})
  end
end

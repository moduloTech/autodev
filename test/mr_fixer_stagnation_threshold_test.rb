# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/mr_fixer'

# task #9 phase 2: the per-project `stagnation_threshold` override now applies
# to discussion-fix stagnation too (it used to read only the global @config).
class MrFixerStagnationThresholdTest < Minitest::Test
  def fixer(project_config: {}, config: {})
    MrFixer.allocate.tap do |m|
      m.instance_variable_set(:@project_config, project_config)
      m.instance_variable_set(:@config, config)
    end
  end

  def test_prefers_project_override_over_global
    m = fixer(project_config: { 'stagnation_threshold' => 3 }, config: { 'stagnation_threshold' => 5 })

    assert_equal 3, m.send(:stagnation_threshold)
  end

  def test_falls_back_to_global_then_baked_default
    assert_equal 5, fixer(config: { 'stagnation_threshold' => 5 }).send(:stagnation_threshold)
    assert_equal 5, fixer.send(:stagnation_threshold)
  end
end

# frozen_string_literal: true

require_relative 'test_helper'

class ConfigLabelWorkflowTest < Minitest::Test
  def test_returns_true_with_non_empty_labels_todo
    assert Config.label_workflow?('labels_todo' => ['todo'])
  end

  def test_returns_false_with_nil
    refute Config.label_workflow?('labels_todo' => nil)
  end

  def test_returns_false_with_empty_array
    refute Config.label_workflow?('labels_todo' => [])
  end

  def test_returns_false_with_non_array
    refute Config.label_workflow?('labels_todo' => 'todo')
  end

  def test_returns_false_when_missing
    refute Config.label_workflow?({})
  end
end

# frozen_string_literal: true

require_relative 'test_helper'

class ConfigValidateLabelsTest < Minitest::Test
  BASE = {
    'gitlab_token' => 'glpat-xxxx', 'poll_interval' => 300, 'max_workers' => 3,
    'dc_timeout' => 1800, 'max_retries' => 3, 'retry_backoff' => 30,
    'pickup_delay' => 600, 'stagnation_threshold' => 5, 'log_level' => 'INFO'
  }.freeze

  def base_config(projects) = BASE.merge('projects' => projects)

  def test_partial_label_config_raises
    config = base_config([{ 'path' => 'g/p', 'labels_todo' => ['todo'] }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_full_label_config_passes
    config = base_config([{
                           'path' => 'g/p', 'labels_todo' => ['todo'],
                           'label_doing' => 'doing', 'label_done' => 'mr'
                         }])
    Config.validate!(config)
  end

  def test_labels_todo_empty_array_raises
    config = base_config([{
                           'path' => 'g/p', 'labels_todo' => [],
                           'label_doing' => 'doing', 'label_done' => 'mr'
                         }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_label_doing_empty_string_raises
    config = base_config([{
                           'path' => 'g/p', 'labels_todo' => ['todo'],
                           'label_doing' => '', 'label_done' => 'mr'
                         }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  # The optional fourth label (Autodev #63). Optional, so its absence is not a
  # partial workflow — but blank is a typo, and setting it without the three
  # required ones configures nothing.
  def test_label_attention_is_optional
    config = base_config([{
                           'path' => 'g/p', 'labels_todo' => ['todo'],
                           'label_doing' => 'doing', 'label_done' => 'mr',
                           'label_attention' => 'attention'
                         }])
    Config.validate!(config)
  end

  def test_label_attention_empty_string_raises
    config = base_config([{
                           'path' => 'g/p', 'labels_todo' => ['todo'],
                           'label_doing' => 'doing', 'label_done' => 'mr',
                           'label_attention' => '  '
                         }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_label_attention_without_the_workflow_raises
    config = base_config([{ 'path' => 'g/p', 'label_attention' => 'attention' }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_no_label_fields_passes
    config = base_config([{ 'path' => 'g/p' }])
    Config.validate!(config)
  end

  # Previously-deprecated label fields (label_mr, label_blocked, …) are now
  # silently ignored — no warning, and validation still passes.
  def test_legacy_label_fields_are_ignored_without_warning
    config = base_config([{
                           'path' => 'g/p', 'labels_todo' => ['todo'],
                           'label_doing' => 'doing', 'label_done' => 'done',
                           'label_mr' => 'mr', 'label_blocked' => 'blocked'
                         }])
    output = capture_io { Config.validate!(config) }[1]

    refute_match(/DEPRECATION/, output)
  end
end

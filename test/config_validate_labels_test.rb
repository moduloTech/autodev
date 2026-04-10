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
                           'label_doing' => 'doing', 'label_mr' => 'mr'
                         }])
    Config.validate!(config)
  end

  def test_labels_todo_empty_array_raises
    config = base_config([{
                           'path' => 'g/p', 'labels_todo' => [],
                           'label_doing' => 'doing', 'label_mr' => 'mr'
                         }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_label_doing_empty_string_raises
    config = base_config([{
                           'path' => 'g/p', 'labels_todo' => ['todo'],
                           'label_doing' => '', 'label_mr' => 'mr'
                         }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_no_label_fields_passes
    config = base_config([{ 'path' => 'g/p' }])
    Config.validate!(config)
  end

  def test_deprecated_label_done_warns
    config = base_config([{
                           'path' => 'g/p', 'labels_todo' => ['todo'],
                           'label_doing' => 'doing', 'label_mr' => 'mr',
                           'label_done' => 'done'
                         }])
    output = capture_io { Config.validate!(config) }[1]

    assert_match(/DEPRECATION.*label_done/, output)
  end

  def test_deprecated_label_blocked_warns
    config = base_config([{
                           'path' => 'g/p', 'labels_todo' => ['todo'],
                           'label_doing' => 'doing', 'label_mr' => 'mr',
                           'label_blocked' => 'blocked'
                         }])
    output = capture_io { Config.validate!(config) }[1]

    assert_match(/DEPRECATION.*label_blocked/, output)
  end
end

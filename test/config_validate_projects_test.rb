# frozen_string_literal: true

require_relative 'test_helper'

class ConfigValidateProjectsTest < Minitest::Test
  def base_config(projects)
    {
      'gitlab_token' => 'glpat-xxxx',
      'poll_interval' => 300,
      'max_workers' => 3,
      'dc_timeout' => 1800,
      'max_retries' => 3,
      'retry_backoff' => 30,
      'max_fix_rounds' => 3,
      'log_level' => 'INFO',
      'projects' => projects
    }
  end

  def test_missing_project_path_raises
    config = base_config([{}])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_empty_project_path_raises
    config = base_config([{ 'path' => '' }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_negative_dc_timeout_raises
    config = base_config([{ 'path' => 'g/p', 'dc_timeout' => -10 }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_valid_project_overrides_pass
    config = base_config([{ 'path' => 'g/p', 'dc_timeout' => 3600, 'max_retries' => 5 }])
    Config.validate!(config) # should not raise
  end

  # -- post_completion --

  def test_post_completion_not_array_raises
    config = base_config([{ 'path' => 'g/p', 'post_completion' => 'deploy.sh' }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_post_completion_empty_array_raises
    config = base_config([{ 'path' => 'g/p', 'post_completion' => [] }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_post_completion_with_non_strings_raises
    config = base_config([{ 'path' => 'g/p', 'post_completion' => [1, 2] }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_post_completion_valid_passes
    config = base_config([{ 'path' => 'g/p', 'post_completion' => ['./deploy.sh', '--env', 'staging'] }])
    Config.validate!(config)
  end

  def test_post_completion_timeout_without_post_completion_raises
    config = base_config([{ 'path' => 'g/p', 'post_completion_timeout' => 600 }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_post_completion_timeout_zero_raises
    config = base_config([{ 'path' => 'g/p', 'post_completion' => ['./run'], 'post_completion_timeout' => 0 }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  # -- clone options --

  def test_clone_depth_negative_raises
    config = base_config([{ 'path' => 'g/p', 'clone_depth' => -1 }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_clone_depth_zero_passes
    config = base_config([{ 'path' => 'g/p', 'clone_depth' => 0 }])
    Config.validate!(config)
  end

  def test_sparse_checkout_not_array_raises
    config = base_config([{ 'path' => 'g/p', 'sparse_checkout' => 'src/' }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_sparse_checkout_empty_raises
    config = base_config([{ 'path' => 'g/p', 'sparse_checkout' => [] }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_sparse_checkout_valid_passes
    config = base_config([{ 'path' => 'g/p', 'sparse_checkout' => ['src/', 'lib/'] }])
    Config.validate!(config)
  end

  # -- label workflow --

  def test_partial_label_config_raises
    config = base_config([{ 'path' => 'g/p', 'labels_todo' => ['todo'] }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_full_label_config_passes
    config = base_config([{
                           'path' => 'g/p',
                           'labels_todo' => ['todo'],
                           'label_doing' => 'doing',
                           'label_mr' => 'mr',
                           'label_done' => 'done',
                           'label_blocked' => 'blocked'
                         }])
    Config.validate!(config)
  end

  def test_labels_todo_empty_array_raises
    config = base_config([{
                           'path' => 'g/p',
                           'labels_todo' => [],
                           'label_doing' => 'doing',
                           'label_mr' => 'mr',
                           'label_done' => 'done',
                           'label_blocked' => 'blocked'
                         }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_label_doing_empty_string_raises
    config = base_config([{
                           'path' => 'g/p',
                           'labels_todo' => ['todo'],
                           'label_doing' => '',
                           'label_mr' => 'mr',
                           'label_done' => 'done',
                           'label_blocked' => 'blocked'
                         }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_no_label_fields_passes
    config = base_config([{ 'path' => 'g/p' }])
    Config.validate!(config)
  end
end

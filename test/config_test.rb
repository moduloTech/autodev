# frozen_string_literal: true

require_relative 'test_helper'

class ConfigValidateTest < Minitest::Test
  def valid_config
    {
      'gitlab_token' => 'glpat-xxxx',
      'gitlab_url' => 'https://gitlab.example.com',
      'poll_interval' => 300,
      'max_workers' => 3,
      'dc_timeout' => 1800,
      'max_retries' => 3,
      'retry_backoff' => 30,
      'max_fix_rounds' => 3,
      'log_level' => 'INFO',
      'projects' => [{ 'path' => 'group/project' }]
    }
  end

  def test_valid_config_passes
    Config.validate!(valid_config)
  end

  def test_missing_gitlab_token_raises
    config = valid_config.merge('gitlab_token' => nil)
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_empty_gitlab_token_raises
    config = valid_config.merge('gitlab_token' => '  ')
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_zero_poll_interval_raises
    config = valid_config.merge('poll_interval' => 0)
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_negative_max_workers_raises
    config = valid_config.merge('max_workers' => -1)
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_invalid_log_level_raises
    config = valid_config.merge('log_level' => 'TRACE')
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_valid_log_levels
    %w[debug INFO Warn ERROR].each do |level|
      config = valid_config.merge('log_level' => level)
      Config.validate!(config) # should not raise
    end
  end

  def test_string_numeric_raises
    config = valid_config.merge('poll_interval' => 'abc')
    assert_raises(ConfigError) { Config.validate!(config) }
  end
end

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

class ConfigLoadTest < Minitest::Test
  def test_defaults_applied
    config = Config.load('config_path' => '/nonexistent/path.yml')

    assert_equal 'autodev', config['trigger_label']
    assert_equal 300, config['poll_interval']
    assert_equal 3, config['max_workers']
  end

  def test_yaml_overrides_defaults
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'config.yml')
      File.write(path, YAML.dump('trigger_label' => 'custom', 'poll_interval' => 60,
                                 'projects' => [{ 'path' => 'g/p' }]))
      config = Config.load('config_path' => path)

      assert_equal 'custom', config['trigger_label']
      assert_equal 60, config['poll_interval']
    end
  end

  def test_env_overrides_yaml
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'config.yml')
      File.write(path, YAML.dump('gitlab_token' => 'from_yaml', 'projects' => []))
      ENV['GITLAB_API_TOKEN'] = 'from_env'
      config = Config.load('config_path' => path)

      assert_equal 'from_env', config['gitlab_token']
    end
  ensure
    ENV.delete('GITLAB_API_TOKEN')
  end

  def test_cli_overrides_env
    ENV['GITLAB_API_TOKEN'] = 'from_env'
    config = Config.load('config_path' => '/nonexistent', 'gitlab_token' => 'from_cli')

    assert_equal 'from_cli', config['gitlab_token']
  ensure
    ENV.delete('GITLAB_API_TOKEN')
  end

  def test_numeric_coercion
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'config.yml')
      File.write(path, YAML.dump('poll_interval' => '120', 'projects' => []))
      config = Config.load('config_path' => path)

      assert_equal 120, config['poll_interval']
      assert_kind_of Integer, config['poll_interval']
    end
  end
end

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

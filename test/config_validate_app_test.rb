# frozen_string_literal: true

require_relative 'test_helper'

class ConfigValidateAppTest < Minitest::Test
  BASE = {
    'gitlab_token' => 'glpat-xxxx', 'poll_interval' => 300, 'max_workers' => 3,
    'dc_timeout' => 1800, 'max_retries' => 3, 'retry_backoff' => 30,
    'pickup_delay' => 600, 'stagnation_threshold' => 5, 'log_level' => 'INFO'
  }.freeze

  def base_config(projects) = BASE.merge('projects' => projects)

  def test_valid_full_config_passes
    app = {
      'setup' => [%w[bundle install], %w[yarn install]],
      'test' => [['bin/test'], ['bin/rswag']],
      'lint' => [%w[bundle exec rubocop -A]]
    }
    config = base_config([{ 'path' => 'g/p', 'app' => app }])
    Config.validate!(config)
  end

  def test_partial_config_passes
    config = base_config([{ 'path' => 'g/p', 'app' => { 'lint' => [%w[bundle exec rubocop]] } }])
    Config.validate!(config)
  end

  def test_empty_hash_passes
    config = base_config([{ 'path' => 'g/p', 'app' => {} }])
    Config.validate!(config)
  end

  def test_not_hash_raises
    config = base_config([{ 'path' => 'g/p', 'app' => 'rails' }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_unknown_key_raises
    config = base_config([{ 'path' => 'g/p', 'app' => { 'deploy' => [['bin/deploy']] } }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_section_not_array_raises
    config = base_config([{ 'path' => 'g/p', 'app' => { 'setup' => 'bundle install' } }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_section_empty_array_raises
    config = base_config([{ 'path' => 'g/p', 'app' => { 'test' => [] } }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_command_not_array_raises
    config = base_config([{ 'path' => 'g/p', 'app' => { 'setup' => ['bundle install'] } }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_command_empty_array_raises
    config = base_config([{ 'path' => 'g/p', 'app' => { 'setup' => [[]] } }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_command_non_string_elements_raises
    config = base_config([{ 'path' => 'g/p', 'app' => { 'setup' => [[1, 2]] } }])
    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_project_without_app_passes
    config = base_config([{ 'path' => 'g/p' }])
    Config.validate!(config)
  end
end

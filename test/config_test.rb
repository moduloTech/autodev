# frozen_string_literal: true

require_relative 'test_helper'

class ConfigValidateTest < Minitest::Test
  VALID_BASE = {
    'gitlab_token' => 'glpat-xxxx', 'gitlab_url' => 'https://gitlab.example.com',
    'poll_interval' => 300, 'max_workers' => 3, 'dc_timeout' => 1800,
    'max_retries' => 3, 'retry_backoff' => 30, 'max_fix_rounds' => 3,
    'log_level' => 'INFO', 'projects' => [{ 'path' => 'group/project' }]
  }.freeze

  def valid_config = VALID_BASE.dup

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

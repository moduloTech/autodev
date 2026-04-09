# frozen_string_literal: true

require_relative 'test_helper'

class ConfigValidateAppRunTest < Minitest::Test
  BASE = {
    'gitlab_token' => 'glpat-xxxx', 'poll_interval' => 300, 'max_workers' => 3,
    'dc_timeout' => 1800, 'max_retries' => 3, 'retry_backoff' => 30,
    'max_fix_rounds' => 3, 'log_level' => 'INFO'
  }.freeze

  def base_config(projects) = BASE.merge('projects' => projects)

  def test_valid_with_port_passes
    app = { 'run' => [{ 'command' => %w[bin/rails s], 'port' => 3000 }] }
    config = base_config([{ 'path' => 'g/p', 'app' => app }])
    Config.validate!(config)
  end

  def test_valid_without_port_passes
    app = { 'run' => [{ 'command' => %w[bin/vite dev] }] }
    config = base_config([{ 'path' => 'g/p', 'app' => app }])
    Config.validate!(config)
  end

  def test_multiple_entries_passes
    app = {
      'run' => [
        { 'command' => %w[bin/rails s], 'port' => 3000 },
        { 'command' => %w[bin/vite dev] },
        { 'command' => %w[bin/webpack], 'port' => 3010 }
      ]
    }
    config = base_config([{ 'path' => 'g/p', 'app' => app }])
    Config.validate!(config)
  end

  def test_not_array_raises
    app = { 'run' => 'bin/rails s' }
    config = base_config([{ 'path' => 'g/p', 'app' => app }])

    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_empty_array_raises
    app = { 'run' => [] }
    config = base_config([{ 'path' => 'g/p', 'app' => app }])

    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_entry_not_hash_raises
    app = { 'run' => [%w[bin/rails s]] }
    config = base_config([{ 'path' => 'g/p', 'app' => app }])

    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_missing_command_raises
    app = { 'run' => [{ 'port' => 3000 }] }
    config = base_config([{ 'path' => 'g/p', 'app' => app }])

    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_command_not_array_raises
    app = { 'run' => [{ 'command' => 'bin/rails s' }] }
    config = base_config([{ 'path' => 'g/p', 'app' => app }])

    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_port_not_integer_raises
    app = { 'run' => [{ 'command' => %w[bin/rails s], 'port' => '3000' }] }
    config = base_config([{ 'path' => 'g/p', 'app' => app }])

    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_port_zero_raises
    app = { 'run' => [{ 'command' => %w[bin/rails s], 'port' => 0 }] }
    config = base_config([{ 'path' => 'g/p', 'app' => app }])

    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_port_too_high_raises
    app = { 'run' => [{ 'command' => %w[bin/rails s], 'port' => 70_000 }] }
    config = base_config([{ 'path' => 'g/p', 'app' => app }])

    assert_raises(ConfigError) { Config.validate!(config) }
  end
end

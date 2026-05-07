# frozen_string_literal: true

require_relative 'test_helper'

class ConfigValidateWebTest < Minitest::Test
  BASE = {
    'gitlab_token' => 'glpat-xxxx', 'poll_interval' => 300, 'max_workers' => 3,
    'dc_timeout' => 1800, 'max_retries' => 3, 'retry_backoff' => 30,
    'pickup_delay' => 600, 'stagnation_threshold' => 5, 'log_level' => 'INFO'
  }.freeze

  def test_default_web_block_passes
    config = BASE.merge('web' => { 'enabled' => true, 'port' => 4567 })

    ConfigValidator.validate_globals!(config)
  end

  def test_disabled_web_block_passes_without_port
    config = BASE.merge('web' => { 'enabled' => false })

    ConfigValidator.validate_globals!(config)
  end

  def test_omitted_web_block_passes
    ConfigValidator.validate_globals!(BASE)
  end

  def test_non_hash_web_block_rejected
    config = BASE.merge('web' => 'enabled')

    assert_raises(ConfigError) { ConfigValidator.validate_globals!(config) }
  end

  def test_non_boolean_enabled_rejected
    config = BASE.merge('web' => { 'enabled' => 'yes', 'port' => 4567 })

    assert_raises(ConfigError) { ConfigValidator.validate_globals!(config) }
  end

  def test_port_below_range_rejected
    config = BASE.merge('web' => { 'enabled' => true, 'port' => 80 })

    assert_raises(ConfigError) { ConfigValidator.validate_globals!(config) }
  end

  def test_port_above_range_rejected
    config = BASE.merge('web' => { 'enabled' => true, 'port' => 70_000 })

    assert_raises(ConfigError) { ConfigValidator.validate_globals!(config) }
  end

  def test_non_integer_port_rejected
    config = BASE.merge('web' => { 'enabled' => true, 'port' => '4567' })

    assert_raises(ConfigError) { ConfigValidator.validate_globals!(config) }
  end
end

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

  def test_omitted_web_block_passes
    ConfigValidator.validate_globals!(BASE)
  end

  def test_non_hash_web_block_rejected
    config = BASE.merge('web' => 'enabled')

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

  def test_bind_accepts_loopback
    config = BASE.merge('web' => { 'enabled' => true, 'port' => 4567, 'bind' => '127.0.0.1' })

    ConfigValidator.validate_globals!(config)
  end

  def test_bind_accepts_zero_addr
    config = BASE.merge('web' => { 'enabled' => true, 'port' => 4567, 'bind' => '0.0.0.0' })

    ConfigValidator.validate_globals!(config)
  end

  def test_bind_accepts_arbitrary_hostname
    config = BASE.merge('web' => { 'enabled' => true, 'port' => 4567, 'bind' => 'bobette.netbird.lan' })

    ConfigValidator.validate_globals!(config)
  end

  def test_empty_bind_rejected
    config = BASE.merge('web' => { 'enabled' => true, 'port' => 4567, 'bind' => '' })

    assert_raises(ConfigError) { ConfigValidator.validate_globals!(config) }
  end

  def test_non_string_bind_rejected
    config = BASE.merge('web' => { 'enabled' => true, 'port' => 4567, 'bind' => 12_345 })

    assert_raises(ConfigError) { ConfigValidator.validate_globals!(config) }
  end
end

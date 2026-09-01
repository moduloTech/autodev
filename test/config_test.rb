# frozen_string_literal: true

require_relative 'test_helper'

class ConfigValidateTest < Minitest::Test
  VALID_BASE = {
    'gitlab_token' => 'glpat-xxxx', 'gitlab_url' => 'https://gitlab.example.com',
    'poll_interval' => 300, 'max_workers' => 3, 'dc_timeout' => 1800,
    'max_retries' => 3, 'retry_backoff' => 30, 'pickup_delay' => 600, 'stagnation_threshold' => 5,
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

  # Optional, so absent is valid (Autodev #80): unset means mr-review shares
  # `gitlab_token`, which is the default this ticket chose.
  def test_an_absent_mr_review_token_is_valid_and_shares_gitlab_token
    Config.validate!(valid_config)

    assert_equal 'glpat-xxxx', Config.mr_review_token(valid_config)
  end

  def test_a_declared_mr_review_token_is_valid_and_is_the_one_mr_review_gets
    config = valid_config.merge('mr_review_token' => 'glpat-yyyy')
    Config.validate!(config)

    assert_equal 'glpat-yyyy', Config.mr_review_token(config)
  end

  # A present-and-blank value would read as the fallback while looking like a
  # separation — the same refusal `label_attention` and `review_skill` get.
  def test_a_blank_mr_review_token_raises
    config = valid_config.merge('mr_review_token' => '   ')

    assert_raises(ConfigError) { Config.validate!(config) }
  end

  def test_a_non_string_mr_review_token_raises
    config = valid_config.merge('mr_review_token' => 12_345)

    assert_raises(ConfigError) { Config.validate!(config) }
  end

  # One resolution for both readers — what the review step exports and what the
  # probe asks GitLab about — and it names the key it came from, which is what
  # the probe records instead of the value.
  def test_the_resolution_names_the_key_the_credential_came_from
    assert_equal %w[glpat-xxxx gitlab_token], Config.mr_review_credential(valid_config)
    assert_equal %w[glpat-yyyy mr_review_token],
                 Config.mr_review_credential(valid_config.merge('mr_review_token' => 'glpat-yyyy'))
  end

  # Nothing declared at all: no credential, and the caller must be able to see
  # that rather than export a blank over mr-review's own configuration.
  def test_no_credential_at_all_resolves_to_nothing
    assert_nil Config.mr_review_credential({})
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

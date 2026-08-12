# frozen_string_literal: true

require_relative 'test_helper'

# Autodev #58 — the config.yml side of the type-vs-range split: every numeric
# setting declared in NumericSettings is coerced only when it really is a
# number, and validated against its declared range instead of the single
# "positive integer" rule Config::INTEGER_FIELDS used to apply to everything.
class ConfigNumericBoundsTest < Minitest::Test
  VALID_BASE = {
    'gitlab_token' => 'glpat-xxxx', 'gitlab_url' => 'https://gitlab.example.com',
    'poll_interval' => 300, 'max_workers' => 3, 'dc_timeout' => 1800,
    'max_retries' => 3, 'retry_backoff' => 30, 'pickup_delay' => 600,
    'stagnation_threshold' => 5, 'log_level' => 'INFO',
    'projects' => [{ 'path' => 'group/project' }]
  }.freeze

  def config(**overrides) = VALID_BASE.merge(overrides)

  def project_config(**overrides)
    config('projects' => [{ 'path' => 'group/project' }.merge(overrides.transform_keys(&:to_s))])
  end

  # -- globals --

  def test_pipeline_watch_max_days_zero_is_accepted_globally
    Config.validate!(config('pipeline_watch_max_days' => 0))
  end

  # CONSTAT 2: without a declared type this coerced to 0 and disabled the age
  # bound in silence.
  def test_non_numeric_pipeline_watch_max_days_is_rejected_globally
    error = assert_raises(ConfigError) { Config.validate!(config('pipeline_watch_max_days' => 'quatorze')) }

    assert_includes error.message, 'pipeline_watch_max_days'
    assert_includes error.message, '"quatorze"'
  end

  def test_pipeline_watch_max_days_has_a_ceiling
    assert_raises(ConfigError) { Config.validate!(config('pipeline_watch_max_days' => 4000)) }
  end

  def test_an_absent_optional_numeric_global_is_not_an_error
    refute_includes VALID_BASE.keys, 'pipeline_watch_max_days'
    Config.validate!(config)
  end

  def test_a_required_numeric_global_still_has_to_be_a_positive_number
    assert_raises(ConfigError) { Config.validate!(config('poll_interval' => 0)) }
    assert_raises(ConfigError) { Config.validate!(config('max_workers' => -1)) }
    assert_raises(ConfigError) { Config.validate!(config('poll_interval' => 'abc')) }
  end

  def test_a_global_timeout_now_has_a_ceiling
    assert_raises(ConfigError) { Config.validate!(config('dc_timeout' => 86_400_000)) }
  end

  def test_the_error_names_the_accepted_range
    error = assert_raises(ConfigError) { Config.validate!(config('dc_timeout' => 86_400_000)) }

    assert_includes error.message, NumericSettings.spec('dc_timeout').max.to_s
  end

  # -- load-time coercion --

  def test_load_coerces_a_numeric_string_for_a_newly_declared_field
    with_config_file('pipeline_watch_max_days' => '30') do |path|
      assert_equal 30, Config.load('config_path' => path)['pipeline_watch_max_days']
    end
  end

  def test_load_does_not_turn_a_non_numeric_value_into_zero
    with_config_file('pipeline_watch_max_days' => 'quatorze') do |path|
      assert_equal 'quatorze', Config.load('config_path' => path)['pipeline_watch_max_days']
    end
  end

  def test_load_leaves_a_non_numeric_required_field_readable_for_the_error_message
    with_config_file('poll_interval' => 'abc') do |path|
      assert_equal 'abc', Config.load('config_path' => path)['poll_interval']
    end
  end

  # -- per-project YAML entries --

  # CONSTAT 1: the dropped-digit typo the ticket names.
  def test_per_project_mr_review_timeout_ceiling
    error = assert_raises(ConfigError) { Config.validate!(project_config(mr_review_timeout: 86_400_000)) }

    assert_includes error.message, 'group/project'
    assert_match(/mr_review_timeout.*21600/, error.message)
  end

  def test_per_project_mr_review_timeout_floor
    assert_raises(ConfigError) { Config.validate!(project_config(mr_review_timeout: 5)) }
    Config.validate!(project_config(mr_review_timeout: 3600))
  end

  def test_per_project_pipeline_watch_max_days_accepts_zero_but_not_a_string
    Config.validate!(project_config(pipeline_watch_max_days: 0))
    assert_raises(ConfigError) { Config.validate!(project_config(pipeline_watch_max_days: 'jamais')) }
  end

  def test_per_project_safety_net_counters_are_validated_too
    assert_raises(ConfigError) { Config.validate!(project_config(infra_recheck_max: 'beaucoup')) }
    assert_raises(ConfigError) { Config.validate!(project_config(dormant_audit_max: 0)) }
    Config.validate!(project_config(infra_recheck_max: 5, dormant_audit_max: 3))
  end

  def test_per_project_clone_depth_keeps_zero_and_rejects_negatives
    Config.validate!(project_config(clone_depth: 0))
    assert_raises(ConfigError) { Config.validate!(project_config(clone_depth: -1)) }
  end

  def test_per_project_post_completion_timeout_is_bounded
    Config.validate!(project_config(post_completion: ['./run'], post_completion_timeout: 300))
    assert_raises(ConfigError) do
      Config.validate!(project_config(post_completion: ['./run'], post_completion_timeout: 86_400_000))
    end
  end

  private

  def with_config_file(yaml)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'config.yml')
      File.write(path, YAML.dump(yaml.merge('projects' => [])))
      yield path
    end
  end
end

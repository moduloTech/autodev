# frozen_string_literal: true

require_relative 'test_helper'

# Autodev #86 — `clarification_max_days`, the age bound on an unanswered
# question. Same shape as `pipeline_watch_max_days` (Autodev #53/#58): `0` is a
# sentinel that switches the bound off, so a value that merely coerces to `0` —
# a word, a typo — must be refused rather than read as "off" in silence.
class ClarificationMaxDaysSettingTest < Minitest::Test
  VALID_BASE = {
    'gitlab_token' => 'glpat-xxxx', 'gitlab_url' => 'https://gitlab.example.com',
    'poll_interval' => 300, 'max_workers' => 3, 'dc_timeout' => 1800,
    'max_retries' => 3, 'retry_backoff' => 30, 'pickup_delay' => 600,
    'stagnation_threshold' => 5, 'log_level' => 'INFO',
    'projects' => [{ 'path' => 'group/project' }]
  }.freeze

  def config(**overrides) = VALID_BASE.merge(overrides)

  def with_project(**overrides)
    config('projects' => [{ 'path' => 'group/project' }.merge(overrides.transform_keys(&:to_s))])
  end

  # -- the lookup: per project → global → default --

  def test_the_default_is_fourteen_days
    assert_equal 14, Config.clarification_max_days({}, {})
  end

  def test_a_project_zero_wins_over_a_global_value
    assert_equal 0, Config.clarification_max_days({ 'clarification_max_days' => 0 },
                                                  { 'clarification_max_days' => 14 })
  end

  def test_the_global_value_applies_when_the_project_sets_none
    assert_equal 5, Config.clarification_max_days({}, { 'clarification_max_days' => 5 })
  end

  # -- the range, globally and per project --

  def test_zero_is_accepted
    Config.validate!(config('clarification_max_days' => 0))
    Config.validate!(with_project(clarification_max_days: 0))
  end

  def test_a_year_is_the_ceiling
    assert_raises(ConfigError) { Config.validate!(config('clarification_max_days' => 366)) }
    assert_raises(ConfigError) { Config.validate!(with_project(clarification_max_days: 366)) }
  end

  def test_a_word_is_refused_and_named
    error = assert_raises(ConfigError) { Config.validate!(config('clarification_max_days' => 'quatorze')) }

    assert_includes error.message, 'clarification_max_days'
    assert_includes error.message, '"quatorze"'
  end

  def test_a_word_is_refused_per_project
    assert_raises(ConfigError) { Config.validate!(with_project(clarification_max_days: 'quatorze')) }
  end
end

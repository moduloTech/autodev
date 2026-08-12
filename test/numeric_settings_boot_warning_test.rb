# frozen_string_literal: true

require_relative 'autodev_test_helper'

# Autodev #58 — the startup warning, modelled on bin/autodev's "mr-review not
# installed" line: a rejected numeric value must be *visible* at boot, naming
# the project, the field and the value.
#
# A bad value in config.yml already aborts the supervisor (ConfigValidator /
# ProjectValidator raise ConfigError). This covers the case that must not abort:
# a value already sitting in the `projects` table, written before the column
# carried a range or written around the validations.
class NumericSettingsBootWarningTest < Minitest::Test
  def setup
    @logger = StubLogger.new
    @pastel = FakePastel.new
    @config = { 'web' => { 'locale' => 'fr' } }
  end

  def violations(project_config)
    NumericSettings.audit([project_config])
  end

  def test_a_healthy_configuration_prints_nothing
    warn_numeric_violations([], @config, @logger, @pastel)

    assert_empty @logger.messages
  end

  def test_the_warning_names_the_project_and_the_field
    warn_numeric_violations(violations('path' => 'group/proj', 'mr_review_timeout' => 86_400_000),
                            @config, @logger, @pastel)
    output = @logger.messages.join("\n")

    assert_includes output, 'group/proj'
    assert_includes output, 'mr_review_timeout'
  end

  def test_the_warning_prints_the_rejected_value_and_the_ceiling_it_broke
    warn_numeric_violations(violations('path' => 'group/proj', 'mr_review_timeout' => 86_400_000),
                            @config, @logger, @pastel)

    assert_match(/86400000.*21600/, @logger.messages.last)
  end

  def test_the_warning_says_a_protection_is_at_stake
    warn_numeric_violations(violations('path' => 'g/p', 'pipeline_watch_max_days' => 'quatorze'),
                            @config, @logger, @pastel)

    assert_includes @logger.messages.first, 'protection'
  end

  def test_one_line_per_rejected_value_plus_a_header
    warn_numeric_violations(violations('path' => 'g/p', 'dc_timeout' => 999_999, 'max_retries' => 0),
                            @config, @logger, @pastel)

    assert_equal 3, @logger.messages.size
  end

  def test_the_warning_follows_the_configured_ui_locale
    warn_numeric_violations(violations('path' => 'g/p', 'dc_timeout' => 999_999),
                            { 'web' => { 'locale' => 'en' } }, @logger, @pastel)

    assert_includes @logger.messages.last, 'is out of bounds'
  end

  def test_the_warning_defaults_to_french_when_no_locale_is_configured
    warn_numeric_violations(violations('path' => 'g/p', 'dc_timeout' => 999_999), {}, @logger, @pastel)

    assert_includes @logger.messages.last, 'hors bornes'
  end
end

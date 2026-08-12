# frozen_string_literal: true

require_relative 'test_helper'

# Autodev #58 — the registry that separates the two questions
# `Config::INTEGER_FIELDS` used to answer with one list: "is this a number?"
# (coercion) and "is it in the acceptable range?" (bounds).
class NumericSettingsTest < Minitest::Test
  # -- coercion (the type question) --

  def test_coerces_integers_and_decimal_strings
    assert_equal 3600, NumericSettings.integer(3600)
    assert_equal 3600, NumericSettings.integer('3600')
    assert_equal 3600, NumericSettings.integer('  3600 ')
  end

  def test_non_numeric_values_do_not_coerce_to_zero
    ['abc', '', '   ', 'ten', nil, true, [], {}].each do |raw|
      assert_nil NumericSettings.integer(raw), "#{raw.inspect} must not read as a number"
    end
  end

  def test_leading_zeroes_are_read_in_base_ten_not_octal
    assert_equal 10, NumericSettings.integer('010')
  end

  def test_floats_coerce_only_when_they_carry_no_fraction
    assert_equal 1800, NumericSettings.integer(1800.0)
    assert_nil NumericSettings.integer(1800.5)
  end

  # -- bounds (the range question) --

  def test_violation_is_nil_for_an_in_range_value
    assert_nil NumericSettings.violation('mr_review_timeout', 3600)
  end

  def test_violation_separates_a_type_error_from_a_range_error
    assert_equal :not_an_integer, NumericSettings.violation('pipeline_watch_max_days', 'abc')
    assert_equal :out_of_range, NumericSettings.violation('pipeline_watch_max_days', 4000)
  end

  # CONSTAT 1 — the typo the ticket names: 86400000 instead of 86400.
  def test_mr_review_timeout_rejects_the_dropped_digit_typo
    assert_equal :out_of_range, NumericSettings.violation('mr_review_timeout', 86_400_000)
  end

  def test_mr_review_timeout_floor_is_inclusive
    assert_equal :out_of_range, NumericSettings.violation('mr_review_timeout', 59)
    assert_nil NumericSettings.violation('mr_review_timeout', 60)
  end

  def test_mr_review_timeout_ceiling_is_inclusive
    assert_nil NumericSettings.violation('mr_review_timeout', 21_600)
    assert_equal :out_of_range, NumericSettings.violation('mr_review_timeout', 21_601)
  end

  # CONSTAT 2 — 0 is a sentinel here (it disables the age bound), so the
  # range admits it; a non-numeric value must still be rejected rather than
  # silently coerced to that same 0.
  def test_pipeline_watch_max_days_admits_zero_as_a_sentinel
    assert_nil NumericSettings.violation('pipeline_watch_max_days', 0)
    assert_equal :out_of_range, NumericSettings.violation('pipeline_watch_max_days', -1)
  end

  def test_timeouts_do_not_admit_zero
    assert_equal :out_of_range, NumericSettings.violation('dc_timeout', 0)
    assert_equal :out_of_range, NumericSettings.violation('post_completion_timeout', 0)
  end

  def test_clone_depth_admits_zero_as_a_full_clone_sentinel
    assert_nil NumericSettings.violation('clone_depth', 0)
    assert_equal :out_of_range, NumericSettings.violation('clone_depth', -1)
  end

  def test_an_undeclared_field_has_no_spec_and_no_violation
    assert_nil NumericSettings.spec('not_a_setting')
    assert_nil NumericSettings.violation('not_a_setting', 'anything')
  end

  # -- the registry must agree with the values the code ships with --

  def test_every_baked_global_default_is_within_its_declared_range
    Config::DEFAULTS.each do |field, value|
      spec = NumericSettings.spec(field)
      next if spec.nil?

      assert_nil NumericSettings.violation(field, value),
                 "Config::DEFAULTS['#{field}'] = #{value.inspect} is outside #{spec.min}..#{spec.max}"
    end
  end

  def test_every_baked_standalone_default_is_within_its_declared_range
    { 'post_completion_timeout' => Config::POST_COMPLETION_TIMEOUT,
      'mr_review_timeout' => Config::MR_REVIEW_TIMEOUT,
      'infra_recheck_max' => PipelineMonitor::DEFAULT_INFRA_RECHECK_MAX,
      'infra_recheck_backoff' => PipelineMonitor::DEFAULT_INFRA_RECHECK_BACKOFF }.each do |field, value|
      assert_nil NumericSettings.violation(field, value), "#{field} default #{value} is out of its declared range"
    end
  end

  def test_every_declared_range_is_ordered
    NumericSettings::SPECS.each_value do |spec|
      assert_operator spec.min, :<, spec.max, "#{spec.field}: min must be below max"
    end
  end

  def test_every_db_backed_integer_column_is_declared
    undeclared = Project::CONFIG_INTEGER_FIELDS.reject { |f| NumericSettings.spec(f.to_s) }

    assert_empty undeclared, "per-project integer columns with no declared range: #{undeclared.inspect}"
  end
end

# The audit over a set of project configs, and the operator-facing line it
# feeds bin/autodev's boot warning.
class NumericSettingsReportingTest < Minitest::Test
  def test_audit_reports_the_offending_project_and_field
    violations = NumericSettings.audit([{ 'path' => 'group/proj', 'mr_review_timeout' => 86_400_000 }])

    assert_equal 1, violations.size
    assert_equal 'group/proj', violations.first.project
    assert_equal 'mr_review_timeout', violations.first.field
  end

  def test_audit_reports_the_value_as_configured_and_why_it_was_rejected
    violation = NumericSettings.audit([{ 'path' => 'group/proj', 'mr_review_timeout' => 86_400_000 }]).first

    assert_equal 86_400_000, violation.value
    assert_equal :out_of_range, violation.reason
  end

  def test_audit_is_silent_on_a_healthy_project
    assert_empty NumericSettings.audit([{ 'path' => 'group/proj', 'dc_timeout' => 1800,
                                          'pipeline_watch_max_days' => 0 }])
  end

  def test_audit_flags_a_non_numeric_pipeline_watch_max_days
    violations = NumericSettings.audit([{ 'path' => 'g/p', 'pipeline_watch_max_days' => 'quatorze' }])

    assert_equal :not_an_integer, violations.first.reason
  end

  def test_audit_ignores_absent_and_nil_settings
    assert_empty NumericSettings.audit([{ 'path' => 'g/p', 'dc_timeout' => nil }])
  end

  # -- the operator-facing line --

  def test_describe_renders_a_real_template_in_both_locales
    violation = NumericSettings.audit([{ 'path' => 'group/proj', 'mr_review_timeout' => 86_400_000 }]).first

    %i[fr en].each do |locale|
      refute_includes NumericSettings.describe(violation, locale: locale), 'cli_numeric',
                      "#{locale} template is missing (the key leaked through)"
    end
  end

  def test_describe_names_the_project_the_field_the_value_and_the_range
    violation = NumericSettings.audit([{ 'path' => 'group/proj', 'mr_review_timeout' => 86_400_000 }]).first
    line = NumericSettings.describe(violation, locale: :fr)

    assert_includes line, 'group/proj'
    assert_includes line, 'mr_review_timeout'
    assert_match(/86400000.*21600/, line)
  end

  def test_describe_uses_a_distinct_wording_for_a_non_numeric_value
    numeric = NumericSettings.audit([{ 'path' => 'g/p', 'dc_timeout' => 99_999_999 }]).first
    textual = NumericSettings.audit([{ 'path' => 'g/p', 'dc_timeout' => 'trente' }]).first

    refute_equal NumericSettings.describe(numeric, locale: :fr),
                 NumericSettings.describe(textual, locale: :fr)
    assert_includes NumericSettings.describe(textual, locale: :fr), 'trente'
  end
end

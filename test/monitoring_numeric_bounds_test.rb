# frozen_string_literal: true

require_relative 'rails_helper'

# The `monitoring:` block was the hole left by Autodev #58.
#
# #58 built a registry so that a numeric setting declares its type and its range
# in one line, and so that a typo is reported instead of coerced. It covered the
# flat top-level globals and the per-project columns. It did not cover the five
# numeric settings that live one level down, under `monitoring:` — and two of
# those arrived in the very same release (Autodev #60's mr-review health check),
# read as `(value || DEFAULT).to_i`.
#
# `.to_i` on a non-number is 0, and 0 is meaningful for all five, so a typo did
# not fail: it reconfigured the setting silently. That is the exact failure mode
# #58 exists to end, which is why the fix is a registry for the block rather than
# two patched readers — the sixth setting added under `monitoring:` must not have
# to remember.
#
# The two directions that matter, both on #60's check:
#
#   * a bad *window* read as 0 s, so the query asked for events newer than "now",
#     counted none, and the check answered `:ok` forever. The alert built so the
#     2026-08-11 outage would show up in hours instead of weeks was off, silently;
#   * a bad *threshold* read as 0, and `count >= 0` is always true, so the check
#     answered `:warn` permanently.
class MonitoringNumericBoundsTest < ActiveSupport::TestCase
  GARBAGE = ['6h', 'six heures', '', 'abc', true, [], {}].freeze

  # --- the registry itself -------------------------------------------------

  def test_every_monitoring_setting_read_by_the_code_is_declared
    NumericSettings::MONITORING_FIELDS.each do |field|
      refute_nil NumericSettings.monitoring_spec(field), "#{field} must declare a range"
    end

    %w[review_failure_window_seconds review_failure_threshold poll_stale_factor
       stuck_active_after_seconds activity_event_retention_seconds].each do |field|
      assert_includes NumericSettings::MONITORING_FIELDS, field
    end
  end

  def test_a_non_numeric_monitoring_value_is_a_type_violation
    GARBAGE.each do |raw|
      assert_equal :not_an_integer,
                   NumericSettings.monitoring_violation('review_failure_window_seconds', raw),
                   "#{raw.inspect} must not read as a number"
    end
  end

  def test_an_absent_monitoring_value_is_not_a_violation
    assert_nil NumericSettings.monitoring_violation('review_failure_threshold', nil)
  end

  def test_a_monitoring_value_outside_its_range_is_a_range_violation
    assert_equal :out_of_range, NumericSettings.monitoring_violation('review_failure_threshold', 0)
    assert_equal :out_of_range, NumericSettings.monitoring_violation('poll_stale_factor', 0)
  end

  # A threshold of 1 means "warn on the first failing ticket" — a deliberate,
  # useful setting. 0 is the value `.to_i` invented, and it is the one that makes
  # the check meaningless.
  def test_a_threshold_of_one_is_legitimate
    assert_nil NumericSettings.monitoring_violation('review_failure_threshold', 1)
  end

  # The two floor-semantics settings must keep accepting the values their own
  # tests exercise: a retention under the safety window is *ignored*, not
  # rejected, and a long forensic retention is allowed.
  def test_the_retention_floor_still_accepts_both_a_narrow_and_a_long_value
    assert_nil NumericSettings.monitoring_violation('activity_event_retention_seconds', 600)
    assert_nil NumericSettings.monitoring_violation('activity_event_retention_seconds', 30 * 86_400)
  end

  # --- config.yml refuses to boot on a bad value ---------------------------

  def test_a_bad_monitoring_value_in_config_yml_is_a_config_error
    error = assert_raises(ConfigError) do
      ConfigValidator.validate_globals!(config_with_monitoring('review_failure_window_seconds' => '6h'))
    end

    assert_includes error.message, 'review_failure_window_seconds'
    assert_includes error.message, '"6h"'
  end

  # Both of these assert on the *reader* rather than on the absence of a raise: a
  # validation that accepts a value is only useful if the value is then the one
  # actually used, and an assertion-free test would pass against a validator that
  # silently dropped the block.
  def test_a_valid_monitoring_block_is_accepted_and_used
    config = config_with_monitoring('review_failure_window_seconds' => 3600, 'review_failure_threshold' => 7)
    ConfigValidator.validate_globals!(config)
    report = Autodev::HealthReport.new(config: config)

    assert_equal [3600, 7], [report.send(:review_failure_window), report.send(:review_failure_threshold)]
  end

  def test_an_absent_monitoring_block_is_accepted_and_leaves_the_defaults
    ConfigValidator.validate_globals!(base_config)
    report = Autodev::HealthReport.new(config: base_config)

    assert_equal [Autodev::HealthReport::DEFAULT_REVIEW_FAILURE_WINDOW,
                  Autodev::HealthReport::DEFAULT_REVIEW_FAILURE_THRESHOLD],
                 [report.send(:review_failure_window), report.send(:review_failure_threshold)]
  end

  # --- the readers degrade to the default, never to zero -------------------

  # Belt and braces with the boot refusal above: HealthReport is also built from
  # a hand-made config by `bin/rails runner`, by the test suite and by anything
  # that skips `validate_globals!`. A garbage value there must fall back to the
  # documented default, which is protective, rather than to 0, which is not.
  def test_a_garbage_window_falls_back_to_the_default_instead_of_zero
    GARBAGE.each do |raw|
      report = Autodev::HealthReport.new(config: monitoring('review_failure_window_seconds' => raw))

      assert_equal Autodev::HealthReport::DEFAULT_REVIEW_FAILURE_WINDOW,
                   report.send(:review_failure_window), "#{raw.inspect} must not read as 0 s"
    end
  end

  def test_a_garbage_threshold_falls_back_to_the_default_instead_of_zero
    GARBAGE.each do |raw|
      report = Autodev::HealthReport.new(config: monitoring('review_failure_threshold' => raw))

      assert_equal Autodev::HealthReport::DEFAULT_REVIEW_FAILURE_THRESHOLD,
                   report.send(:review_failure_threshold), "#{raw.inspect} must not read as 0"
    end
  end

  # The regression that motivated the finding: with the window at 0 the query
  # window is empty, so nothing is ever counted and the check cannot warn.
  def test_the_alert_still_fires_when_the_window_is_misconfigured
    3.times { |i| review_failure_event(issue_id: 900 + i) }
    report = Autodev::HealthReport.new(config: monitoring('review_failure_window_seconds' => 'six heures'))

    assert_equal :warn, report.check(:mr_review)[:status]
  end

  # Its mirror: with the threshold at 0 the check warns on a perfectly healthy
  # instance, because `0 >= 0`.
  def test_a_healthy_instance_stays_ok_when_the_threshold_is_misconfigured
    report = Autodev::HealthReport.new(config: monitoring('review_failure_threshold' => 'trois'))

    assert_equal :ok, report.check(:mr_review)[:status]
  end

  def test_a_garbage_retention_still_clears_the_safety_window
    janitor = Autodev::ActivityEventJanitor.new(
      config: monitoring('activity_event_retention_seconds' => 'vingt-quatre heures')
    )

    assert_operator janitor.retention_seconds, :>,
                    Autodev::HealthReport.new(config: {}).stuck_active_after
  end

  private

  def base_config
    { 'gitlab_token' => 'glpat-xxxx', 'gitlab_url' => 'https://gitlab.example.com',
      'poll_interval' => 300, 'max_workers' => 3, 'dc_timeout' => 1800, 'max_retries' => 3,
      'retry_backoff' => 30, 'pickup_delay' => 600, 'stagnation_threshold' => 5,
      'log_level' => 'INFO' }
  end

  def config_with_monitoring(block) = base_config.merge('monitoring' => block)

  def monitoring(block) = { 'monitoring' => block }

  def review_failure_event(issue_id:)
    ActivityEvent.create!(issue_id: issue_id, kind: 'danger_claude', level: 'info',
                          payload_json: '{"key":"review_failed","iid":1}',
                          created_at: Time.current - 600)
  end
end

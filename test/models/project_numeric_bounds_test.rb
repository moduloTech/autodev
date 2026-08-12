# frozen_string_literal: true

require_relative '../rails_helper'

# Autodev #58 — the two-step numeric validation on the per-project config
# columns: `numericality` answers the type question, #validate_numeric_ranges
# applies the range each field declares in NumericSettings. The dashboard's
# config form is the caller that matters (it is the path a typo arrives
# through); these pin the model that backs it.
class ProjectNumericBoundsTest < ActiveSupport::TestCase
  def project(**attrs)
    Project.new(gitlab_path: 'g/p', slug: 'g__p', **attrs)
  end

  # CONSTAT 1: the ticket's dropped-digit typo. With no ceiling this widened
  # HealthReport's dormant-detection window to years, switching off both
  # mechanisms that catch a dead worker.
  def test_mr_review_timeout_rejects_a_value_above_its_ceiling
    record = project(mr_review_timeout: 86_400_000)

    refute_predicate record, :valid?
    assert_equal :out_of_range, record.errors.first.type
  end

  def test_the_error_message_names_the_declared_ceiling
    record = project(mr_review_timeout: 86_400_000)
    record.valid?

    assert_includes record.errors.first.message, NumericSettings.spec('mr_review_timeout').max.to_s
  end

  def test_mr_review_timeout_rejects_a_value_below_its_floor
    refute_predicate project(mr_review_timeout: 59), :valid?
    assert_predicate project(mr_review_timeout: 60), :valid?
  end

  def test_every_timeout_column_shares_the_declared_ceiling
    %i[dc_timeout post_completion_timeout].each do |field|
      refute_predicate project(field => 86_400_000, post_completion: ['./run']), :valid?
    end
  end

  def test_a_non_numeric_value_is_reported_as_a_type_error
    record = project(dc_timeout: 'trente')

    refute_predicate record, :valid?
    assert_equal :not_a_number, record.errors.first.type
  end

  # AR casts 'trente' to 0 on an integer column, which the range check would
  # otherwise also flag — one wrong entry, two contradictory reasons.
  def test_a_non_numeric_value_is_not_also_reported_as_out_of_range
    record = project(dc_timeout: 'trente')
    record.valid?

    assert_equal 1, record.errors.size
  end

  def test_every_integer_column_gets_its_bounds_from_the_registry
    Project::CONFIG_INTEGER_FIELDS.each do |field|
      spec = NumericSettings.spec(field.to_s)
      attrs = { field => spec.max + 1 }
      attrs[:post_completion] = ['./run'] if field == :post_completion_timeout

      refute_predicate project(**attrs), :valid?, "#{field} accepted #{spec.max + 1}"
    end
  end

  def test_clone_depth_still_admits_zero
    assert_predicate project(clone_depth: 0), :valid?
    refute_predicate project(clone_depth: -1), :valid?
  end
end

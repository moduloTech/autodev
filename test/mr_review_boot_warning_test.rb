# frozen_string_literal: true

require_relative 'autodev_test_helper'

# Autodev #74, fix round 2 — spec §7: "it remains an optional Homebrew
# dependency; the boot warning should only fire when some project actually relies
# on the binary."
#
# The warning fired unconditionally, and since a project declaring `review_skill`
# runs its review through `danger-claude` and never shells out to `mr-review`, it
# announced a skipped review that will not be skipped. Modelled on
# test/numeric_settings_boot_warning_test.rb: the predicate is tested directly, so
# nothing here touches the `projects` table or PATH.
class MrReviewBootWarningTest < Minitest::Test
  def test_a_project_with_no_review_skill_still_relies_on_the_binary
    assert any_project_relies_on_mr_review?([{ 'path' => 'g/a' }])
  end

  def test_a_project_that_declares_a_review_skill_does_not
    refute any_project_relies_on_mr_review?([{ 'path' => 'g/a', 'review_skill' => 'mr-review' }])
  end

  # `''` is truthy in Ruby and `Project#to_project_config` emits every column,
  # so a blank has to read as "no skill declared" here exactly as it does in
  # `launch_review`.
  def test_a_blank_review_skill_reads_as_no_skill_at_all
    assert any_project_relies_on_mr_review?([{ 'path' => 'g/a', 'review_skill' => '   ' }])
  end

  # One project left on the binary is enough: the warning is about the binary
  # being missing, not about the majority of the fleet.
  def test_one_project_on_the_binary_among_several_is_enough
    assert any_project_relies_on_mr_review?(
      [{ 'path' => 'g/a', 'review_skill' => 'mr-review' }, { 'path' => 'g/b' }]
    )
  end

  def test_a_fleet_entirely_on_the_skill_path_needs_no_warning
    refute any_project_relies_on_mr_review?(
      [{ 'path' => 'g/a', 'review_skill' => 'mr-review' }, { 'path' => 'g/b', 'review_skill' => 'prepare-mr' }]
    )
  end

  # The string is user-facing CLI output, so it goes through `Locales.t` in both
  # languages like every other boot diagnostic (CLAUDE.md's locale table).
  def test_the_warning_is_localized_in_both_languages
    %i[fr en].each do |locale|
      message = Locales.t(:cli_mr_review_missing, locale: locale)

      assert_includes message, 'mr-review'
      refute_equal 'cli_mr_review_missing', message
    end
  end
end

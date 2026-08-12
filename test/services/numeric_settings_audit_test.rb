# frozen_string_literal: true

require_relative '../rails_helper'

# Autodev #58 — the composition bin/autodev's boot warning is built on:
# NumericSettings.audit over the configs the poller will actually run with
# (Project.runtime_configs). The validations cannot be the whole answer here —
# a row written around them (the YAML importer, a rake task, `update_column`,
# a manual UPDATE, or simply a row that predates the range) is exactly what the
# boot warning exists to surface.
class NumericSettingsAuditTest < ActiveSupport::TestCase
  test 'flags a DB row whose value was written around the validations' do
    project = Project.create!(gitlab_path: 'group/proj', slug: 'group__proj')
    project.update_column(:mr_review_timeout, 86_400_000)

    violations = NumericSettings.audit(Project.runtime_configs(nil))

    assert_equal 1, violations.size
    assert_equal %w[group/proj mr_review_timeout],
                 [violations.first.project, violations.first.field]
  end

  test 'carries the rejected value through so the boot warning can print it' do
    project = Project.create!(gitlab_path: 'group/proj', slug: 'group__proj')
    project.update_column(:mr_review_timeout, 86_400_000)

    assert_equal 86_400_000, NumericSettings.audit(Project.runtime_configs(nil)).first.value
  end

  test 'stays silent on a project that overrides nothing' do
    Project.create!(gitlab_path: 'group/proj', slug: 'group__proj')

    assert_empty NumericSettings.audit(Project.runtime_configs(nil))
  end

  test 'also covers a YAML-only project not yet imported into the table' do
    violations = NumericSettings.audit(
      Project.runtime_configs([{ 'path' => 'group/yaml', 'pipeline_watch_max_days' => 'quatorze' }])
    )

    assert_equal 'group/yaml', violations.first.project
    assert_equal :not_an_integer, violations.first.reason
  end
end

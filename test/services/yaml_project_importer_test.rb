# frozen_string_literal: true

require_relative '../rails_helper'

# Import-write tests for YamlProjectImporter. Validation-only tests live in
# `yaml_project_importer_validation_test.rb` to keep both classes small.
class YamlProjectImporterTest < ActiveSupport::TestCase
  MINIMAL_YAML = {
    'projects' => [
      { 'path' => 'group/foo' },
      { 'path' => 'group/bar', 'name' => 'Bar (Custom Name)' }
    ]
  }.freeze

  FULL_YAML = {
    'projects' => [
      {
        'path' => 'group/with-app',
        'app' => {
          'setup' => [%w[bundle install], %w[yarn install]],
          'test' => [%w[bin/rails test]],
          'lint' => [['bundle', 'exec', 'rubocop', '-A']],
          'run' => [
            { 'command' => ['bin/rails', 'server'], 'port' => 3000 },
            { 'command' => ['bin/vite', 'dev'] }
          ]
        }
      }
    ]
  }.freeze

  def test_creates_projects_with_derived_slug_and_name
    YamlProjectImporter.new(yaml: MINIMAL_YAML).import!
    foo = Project.find_by!(gitlab_path: 'group/foo')

    assert_equal 'group__foo', foo.slug
    assert_equal 'foo',        foo.name
  end

  def test_uses_explicit_name_when_provided
    YamlProjectImporter.new(yaml: MINIMAL_YAML).import!
    bar = Project.find_by!(gitlab_path: 'group/bar')

    assert_equal 'Bar (Custom Name)', bar.name
  end

  def test_returns_created_count
    summary = YamlProjectImporter.new(yaml: MINIMAL_YAML).import!

    assert_equal 2, summary.created
    assert_equal 0, summary.updated
  end

  def test_re_import_updates_in_place_without_duplicates
    YamlProjectImporter.new(yaml: MINIMAL_YAML).import!
    summary = YamlProjectImporter.new(yaml: MINIMAL_YAML).import!

    assert_equal 2, Project.count
    assert_equal 0, summary.created
    assert_equal 2, summary.updated
  end

  def test_re_import_rebuilds_app_commands_from_scratch
    YamlProjectImporter.new(yaml: FULL_YAML).import!
    initial_ids = ProjectAppCommand.pluck(:id).sort

    YamlProjectImporter.new(yaml: FULL_YAML).import!
    rebuilt_ids = ProjectAppCommand.pluck(:id).sort

    assert_equal initial_ids.size, rebuilt_ids.size
    assert_empty(initial_ids & rebuilt_ids)
  end

  def test_creates_app_commands_with_correct_categories_and_order
    YamlProjectImporter.new(yaml: FULL_YAML).import!
    project = Project.find_by!(gitlab_path: 'group/with-app')
    setup_cmds = project.app_commands.where(category: 'setup').order(:position).map(&:command)

    assert_equal [%w[bundle install], %w[yarn install]], setup_cmds
  end

  def test_run_entry_preserves_port
    YamlProjectImporter.new(yaml: FULL_YAML).import!
    project = Project.find_by!(gitlab_path: 'group/with-app')
    run_cmds = project.app_commands.where(category: 'run').order(:position)

    assert_equal 3000, run_cmds.first.port
    assert_nil run_cmds.second.port
  end

  def test_summary_counts_setup_and_run_categories
    summary = YamlProjectImporter.new(yaml: FULL_YAML).import!

    assert_equal 2, summary.app_commands_by_category['setup']
    assert_equal 2, summary.app_commands_by_category['run']
  end

  def test_summary_counts_test_and_lint_categories
    summary = YamlProjectImporter.new(yaml: FULL_YAML).import!

    assert_equal 1, summary.app_commands_by_category['test']
    assert_equal 1, summary.app_commands_by_category['lint']
  end

  def test_dry_run_rolls_back_transaction
    summary = YamlProjectImporter.new(yaml: MINIMAL_YAML).import!(dry_run: true)

    assert_equal 0, Project.count
    assert summary.dry_run
    assert_equal 2, summary.created
  end

  def test_dry_run_does_not_disturb_existing_rows
    YamlProjectImporter.new(yaml: MINIMAL_YAML).import!
    YamlProjectImporter.new(yaml: { 'projects' => [{ 'path' => 'never/written' }] }).import!(dry_run: true)

    assert_equal 2, Project.count
    refute Project.exists?(gitlab_path: 'never/written')
  end

  def test_summary_to_s_includes_counts_and_dry_run_marker
    summary = YamlProjectImporter.new(yaml: MINIMAL_YAML).import!(dry_run: true)

    assert_match(/2 created/, summary.to_s)
    assert_match(/dry-run/, summary.to_s)
  end
end

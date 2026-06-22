# frozen_string_literal: true

require_relative '../rails_helper'

# Covers the per-project config columns the importer mirrors from YAML
# (task #9 phase 1). Separate from the main importer test to keep both under
# rubocop's class-length limit.
class YamlProjectImporterConfigTest < ActiveSupport::TestCase
  CONFIG_YAML = {
    'projects' => [
      {
        'path' => 'group/cfg', 'target_branch' => 'develop', 'dc_timeout' => 900,
        'labels_todo' => %w[todo to-do], 'label_doing' => 'doing', 'label_done' => 'done',
        'post_completion' => ['./bin/deploy'], 'post_completion_timeout' => 300
      }
    ]
  }.freeze

  def test_imports_scalar_config_columns
    YamlProjectImporter.new(yaml: CONFIG_YAML).import!
    project = Project.find_by!(gitlab_path: 'group/cfg')

    assert_equal 'develop', project.target_branch
    assert_equal 900, project.dc_timeout
  end

  def test_imports_list_config_columns
    YamlProjectImporter.new(yaml: CONFIG_YAML).import!
    project = Project.find_by!(gitlab_path: 'group/cfg')

    assert_equal %w[todo to-do], project.labels_todo
    assert_equal ['./bin/deploy'], project.post_completion
  end

  def test_imports_advanced_config_columns
    yaml = { 'projects' => [{ 'path' => 'group/adv', 'model' => 'opus',
                              'parallel_agents' => true, 'mr_fixer_agent' => 'custom' }] }
    YamlProjectImporter.new(yaml: yaml).import!
    project = Project.find_by!(gitlab_path: 'group/adv')

    assert_equal 'opus', project.model
    assert project.parallel_agents
    assert_equal 'custom', project.mr_fixer_agent
  end

  def test_re_import_clears_dropped_config_keys
    YamlProjectImporter.new(yaml: CONFIG_YAML).import!
    YamlProjectImporter.new(yaml: { 'projects' => [{ 'path' => 'group/cfg' }] }).import!
    project = Project.find_by!(gitlab_path: 'group/cfg')

    assert_nil project.target_branch
    assert_nil project.labels_todo
  end
end

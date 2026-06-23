# frozen_string_literal: true

require_relative '../rails_helper'

# Per-project config columns added in task #9 phase 1: validations mirroring
# lib/autodev/project_validator.rb, and #to_project_config (the YAML-shaped
# hash the runtime read-path will switch onto in phase 2).
class ProjectConfigTest < ActiveSupport::TestCase
  def project(**attrs)
    Project.new(gitlab_path: 'g/p', slug: 'g__p', **attrs)
  end

  # -- validations --

  def test_positive_int_fields_reject_zero_and_negatives
    assert_predicate project(dc_timeout: 600), :valid?
    refute_predicate project(dc_timeout: 0), :valid?
    refute_predicate project(max_retries: -1), :valid?
  end

  def test_clone_depth_allows_zero_but_not_negative
    assert_predicate project(clone_depth: 0), :valid?
    refute_predicate project(clone_depth: -1), :valid?
  end

  def test_partial_label_workflow_is_invalid
    p = project(labels_todo: ['todo'])

    refute_predicate p, :valid?
    assert_includes p.errors[:base].join, 'label workflow'
  end

  def test_complete_label_workflow_is_valid
    assert_predicate project(labels_todo: ['todo'], label_doing: 'doing', label_done: 'done'), :valid?
  end

  def test_labels_todo_must_be_a_non_empty_string_array
    refute_predicate project(labels_todo: [], label_doing: 'd', label_done: 'D'), :valid?
    refute_predicate project(sparse_checkout: [123]), :valid?
  end

  def test_post_completion_timeout_requires_post_completion
    refute_predicate project(post_completion_timeout: 300), :valid?
    assert_predicate project(post_completion: ['./bin/deploy'], post_completion_timeout: 300), :valid?
  end

  def test_all_config_optional
    assert_predicate project, :valid?
  end

  # -- advanced keys (phase 2) --

  def test_advanced_string_fields_reject_blank_but_allow_nil
    assert_predicate project(model: 'opus'), :valid? # set + non-blank is fine
    refute_predicate project(model: '  '), :valid?
    refute_predicate project(mr_fixer_agent: ''), :valid?
  end

  def test_boolean_fields_accept_true_false_and_nil
    assert_predicate project(parallel_agents: true), :valid?
    assert_predicate project(split_implementation: false), :valid?
    assert_predicate project, :valid?
  end

  # -- to_project_config --

  def test_to_project_config_omits_blank_keys
    cfg = project.tap(&:save!).to_project_config

    assert_equal({ 'path' => 'g/p' }, cfg)
  end

  def test_to_project_config_emits_present_scalars_and_lists
    p = project(target_branch: 'develop', dc_timeout: 900, labels_todo: ['todo'],
                label_doing: 'doing', label_done: 'done')
    p.save!

    assert_equal({ 'path' => 'g/p', 'target_branch' => 'develop', 'dc_timeout' => 900,
                   'label_doing' => 'doing', 'label_done' => 'done', 'labels_todo' => ['todo'] },
                 p.to_project_config)
  end

  def test_to_project_config_emits_advanced_keys
    p = project(model: 'opus', parallel_agents: true, mr_fixer_agent: 'custom')
    p.save!

    assert_equal({ 'path' => 'g/p', 'model' => 'opus', 'parallel_agents' => true,
                   'mr_fixer_agent' => 'custom' }, p.to_project_config)
  end

  def test_to_project_config_rebuilds_app_block_from_app_commands
    p = project
    p.save!
    p.app_commands.create!(category: 'setup', command: %w[bundle install], position: 0)
    p.app_commands.create!(category: 'run', command: ['bin/rails', 's'], port: 3000, position: 0)
    cfg = p.reload.to_project_config

    assert_equal [%w[bundle install]], cfg['app']['setup']
    assert_equal [{ 'command' => ['bin/rails', 's'], 'port' => 3000 }], cfg['app']['run']
  end

  # -- runtime_configs (phase 4 discovery) --

  def test_runtime_configs_returns_db_rows_authoritatively
    project(target_branch: 'develop').save!
    configs = Project.runtime_configs(nil)

    assert_equal 1, configs.size
    assert_equal 'develop', configs.first['target_branch']
  end

  def test_runtime_configs_unions_yaml_only_projects_not_in_the_db
    project.save! # g/p exists in the DB
    yaml = [{ 'path' => 'g/p', 'target_branch' => 'ignored' }, { 'path' => 'other/repo' }]
    paths = Project.runtime_configs(yaml).map { |c| c['path'] }

    assert_includes paths, 'other/repo' # YAML-only project kept
    assert_equal 1, paths.count('g/p') # DB row wins, not duplicated by YAML
  end
end

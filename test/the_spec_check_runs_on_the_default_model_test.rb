# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/danger_claude_runner'
require 'autodev/issue_notifier'
require 'autodev/label_manager'
require 'autodev/activity_logger'
require 'autodev/issue_processor'
require 'autodev/pipeline_monitor'
require 'tmpdir'

# Autodev #122. The spec check used to ask for `model: 'haiku'`, the per-call
# default `dc_global_args` falls back to when neither the project nor the
# global config names a model. It no longer asks for anything: the check runs
# on Claude Code's default model.
#
# The `model` / `effort` settings are deprecated by the same ticket but still
# read until they are removed, so the precedence they had (project > global >
# per-call default) is pinned here too — deprecated means signalled, not ignored.
class TheSpecCheckRunsOnTheDefaultModelTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_CONFIG = { 'path' => 'group/project', 'labels_todo' => ['To do'],
                     'label_doing' => 'Doing', 'label_done' => 'Done' }.freeze
  CONFIG = { 'gitlab_url' => 'https://gitlab.example', 'gitlab_token' => 'x' }.freeze
  ENVELOPE = { 'result' => '{"type": "implementation", "issues": []}', 'session_id' => 's' }.to_json

  Paginated = Struct.new(:items) do
    def auto_paginate = items
  end

  class Client
    def issue_notes(*, **) = Paginated.new([])
    def create_issue_note(*) = Struct.new(:id).new(1)
    def edit_issue_note(*) = nil
  end

  def setup
    setup_database
    @issue = create_issue(status: 'pending', branch_name: 'autodev/1-x')
    @issue.start_processing!
    @issue.clone_complete!
  end

  # The argument vector danger-claude received for the spec check.
  def spec_check_args(config: CONFIG, project_config: PROJECT_CONFIG)
    processor = IssueProcessor.new(client: Client.new, config: config, project_config: project_config,
                                   logger: StubLogger.new, token: 'x')
    seen = []
    processor.define_singleton_method(:run_with_timeout) do |_cmd, args, **|
      seen << args
      [ENVELOPE, '', true]
    end
    Dir.mktmpdir { |dir| processor.send(:check_specification, dir, '# ctx', @issue.issue_iid, @issue) }
    seen.first
  end

  def flag_value(args, flag)
    index = args.index(flag)
    index && args[index + 1]
  end

  def test_nothing_configured_passes_no_model
    args = spec_check_args

    refute_includes args, '-m'
    refute_includes args, 'haiku'
  end

  def test_a_global_model_is_still_honoured
    args = spec_check_args(config: CONFIG.merge('model' => 'claude-opus-4-7'))

    assert_equal 'claude-opus-4-7', flag_value(args, '-m')
  end

  def test_a_project_model_wins_over_the_global_one
    args = spec_check_args(config: CONFIG.merge('model' => 'claude-opus-4-7'),
                           project_config: PROJECT_CONFIG.merge('model' => 'sonnet'))

    assert_equal 'sonnet', flag_value(args, '-m')
  end

  def test_a_global_effort_is_still_honoured
    args = spec_check_args(config: CONFIG.merge('effort' => 'xhigh'))

    assert_equal 'xhigh', flag_value(args, '-e')
  end

  def test_a_project_effort_wins_over_the_global_one
    args = spec_check_args(config: CONFIG.merge('effort' => 'xhigh'),
                           project_config: PROJECT_CONFIG.merge('effort' => 'high'))

    assert_equal 'high', flag_value(args, '-e')
  end

  # The verdict still arrives through the real envelope parsing.
  def test_the_check_still_reaches_its_verdict
    spec_check_args

    assert_equal 'implementing', @issue.reload.status
  end

  # A blank value is not a choice of model: a `model: ""` left in config.yml
  # used to reach danger-claude as `-m ''` (an empty string is truthy in Ruby),
  # while the boot warning, which skips blanks, said nothing about it.
  def test_a_blank_setting_passes_nothing
    args = spec_check_args(config: CONFIG.merge('model' => '', 'effort' => ' '),
                           project_config: PROJECT_CONFIG.merge('model' => ''))

    refute_includes args, '-m'
    refute_includes args, '-e'
  end
end

# The two calls that keep asking for haiku, by design (Autodev #122): cheap JSON
# tasks. A deprecated global `model` overrides that per-call default today, so
# removing the setting is what gives them haiku back — both halves pinned here.
class TheCheapEvaluationsKeepHaikuTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_CONFIG = TheSpecCheckRunsOnTheDefaultModelTest::PROJECT_CONFIG
  CONFIG = TheSpecCheckRunsOnTheDefaultModelTest::CONFIG

  def setup = setup_database

  def recording(worker)
    seen = []
    worker.define_singleton_method(:run_with_timeout) do |_cmd, args, **|
      seen << args
      [{ 'result' => '{}' }.to_json, '', true]
    end
    seen
  end

  def model_flag(args)
    index = args.index('-m')
    index && args[index + 1]
  end

  def complexity_args(config)
    processor = IssueProcessor.new(client: nil, config: config, project_config: PROJECT_CONFIG,
                                   logger: StubLogger.new, token: 'x')
    processor.instance_variable_set(:@current_branch_name, 'autodev/1-x')
    seen = recording(processor)
    Dir.mktmpdir { |dir| processor.send(:evaluate_complexity, dir, '# ctx', 1) }
    seen.first
  end

  def pipeline_eval_args(config)
    monitor = PipelineMonitor.new(client: nil, config: config, project_config: PROJECT_CONFIG,
                                  logger: StubLogger.new, token: 'x')
    seen = recording(monitor)
    Dir.mktmpdir { |dir| monitor.send(:evaluate_code_related, dir, '- job: tmp/ci_logs/job.log') }
    seen.first
  end

  def test_the_complexity_evaluation_asks_for_haiku
    assert_equal 'haiku', model_flag(complexity_args(CONFIG))
  end

  def test_the_pipeline_evaluation_asks_for_haiku
    assert_equal 'haiku', model_flag(pipeline_eval_args(CONFIG))
  end

  def test_a_global_model_still_overrides_the_complexity_evaluation
    assert_equal 'claude-opus-4-7', model_flag(complexity_args(CONFIG.merge('model' => 'claude-opus-4-7')))
  end

  def test_a_global_model_still_overrides_the_pipeline_evaluation
    assert_equal 'claude-opus-4-7', model_flag(pipeline_eval_args(CONFIG.merge('model' => 'claude-opus-4-7')))
  end

  def test_a_blank_global_model_leaves_haiku
    assert_equal 'haiku', model_flag(pipeline_eval_args(CONFIG.merge('model' => '')))
  end
end

# frozen_string_literal: true

require_relative 'autodev_test_helper'

# Coverage for the B+C resolution helper that decides which project's label
# names the `/help` guide shows: defaults when nothing is configured, direct
# injection when all visible projects agree, a selector when they differ.
class HelpLabelResolutionTest < Minitest::Test
  # Minimal host for Web::Helpers with an injectable visible-project list,
  # so the resolution logic is exercised without the Project table / SSO.
  class Host
    include ::Web::Helpers

    attr_accessor :visible

    def visible_project_paths
      @visible || []
    end
  end

  A = { 'path' => 'g/a', 'labels_todo' => ['To Do'], 'label_doing' => 'Doing', 'label_done' => 'Done' }.freeze
  B = { 'path' => 'g/b', 'labels_todo' => ['todo'], 'label_doing' => 'wip', 'label_done' => 'shipped' }.freeze

  def setup
    @host = Host.new
    @saved_config = ::Web.config
  end

  def teardown
    ::Web.config = @saved_config
  end

  def with_projects(projects, visible:)
    ::Web.config = { 'projects' => projects }
    @host.visible = visible
  end

  def test_no_configured_project_yields_defaults_and_no_selector
    with_projects([{ 'path' => 'g/a' }], visible: ['g/a'])

    result = @host.help_label_resolution

    assert_empty result[:labels]
    assert_nil result[:selector]
  end

  def test_uniform_labels_inject_directly_without_selector
    with_projects([A, A.merge('path' => 'g/b')], visible: ['g/a', 'g/b'])

    result = @host.help_label_resolution

    assert_nil result[:selector], 'identical label sets need no picker'
    assert_equal 'To Do', result[:labels]['label_todo']
  end

  def test_distinct_labels_default_to_first_project_with_selector
    with_projects([A, B], visible: ['g/a', 'g/b'])

    result = @host.help_label_resolution

    assert_equal 'To Do', result[:labels]['label_todo']
    assert_equal 'g/a', result[:selector][:selected]
  end

  def test_valid_selected_path_is_honored
    with_projects([A, B], visible: ['g/a', 'g/b'])

    result = @host.help_label_resolution('g/b')

    assert_equal 'todo', result[:labels]['label_todo']
    assert_equal 'g/b', result[:selector][:selected]
  end

  def test_unknown_selected_path_falls_back_to_first
    with_projects([A, B], visible: ['g/a', 'g/b'])

    result = @host.help_label_resolution('hidden/x')

    assert_equal 'To Do', result[:labels]['label_todo'], 'an unseen path cannot select its labels'
  end
end

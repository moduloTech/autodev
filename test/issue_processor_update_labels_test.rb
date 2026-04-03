# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/issue_processor'

# Tests for IssueProcessor#update_labels.
class IssueProcessorUpdateLabelsTest < Minitest::Test
  def setup
    @processor = IssueProcessor.allocate
    logger = StubLogger.new
    logger.define_singleton_method(:error) { |msg, **_opts| @messages << msg }
    logger.define_singleton_method(:debug) { |msg, **_opts| @messages << msg }
    @processor.instance_variable_set(:@logger, logger)
    @processor.instance_variable_set(:@project_path, 'group/project')
  end

  def test_removes_specified_labels_and_adds_new_label
    @processor.instance_variable_set(:@project_config, {
                                       'labels_to_remove' => %w[autodev todo],
                                       'label_to_add' => 'in-review'
                                     })
    client = build_client(labels: %w[autodev todo bug])
    @processor.instance_variable_set(:@client, client)

    @processor.send(:update_labels, 42)

    assert_equal 'bug,in-review', client.edited_labels
  end

  def test_does_not_duplicate_label_to_add_if_already_present
    @processor.instance_variable_set(:@project_config, {
                                       'labels_to_remove' => ['autodev'],
                                       'label_to_add' => 'bug'
                                     })
    client = build_client(labels: %w[autodev bug])
    @processor.instance_variable_set(:@client, client)

    @processor.send(:update_labels, 42)

    assert_equal 'bug', client.edited_labels
  end

  def test_handles_nil_label_to_add
    @processor.instance_variable_set(:@project_config, {
                                       'labels_to_remove' => ['autodev'],
                                       'label_to_add' => nil
                                     })
    client = build_client(labels: %w[autodev bug])
    @processor.instance_variable_set(:@client, client)

    @processor.send(:update_labels, 42)

    assert_equal 'bug', client.edited_labels
  end

  def test_handles_empty_labels_to_remove
    @processor.instance_variable_set(:@project_config, {
                                       'labels_to_remove' => [],
                                       'label_to_add' => 'done'
                                     })
    client = build_client(labels: %w[bug])
    @processor.instance_variable_set(:@client, client)

    @processor.send(:update_labels, 42)

    assert_equal 'bug,done', client.edited_labels
  end

  def test_handles_nil_labels_to_remove
    @processor.instance_variable_set(:@project_config, {
                                       'labels_to_remove' => nil,
                                       'label_to_add' => 'done'
                                     })
    client = build_client(labels: %w[bug])
    @processor.instance_variable_set(:@client, client)

    @processor.send(:update_labels, 42)

    assert_equal 'bug,done', client.edited_labels
  end

  def test_handles_nil_issue_labels
    @processor.instance_variable_set(:@project_config, {
                                       'labels_to_remove' => ['autodev'],
                                       'label_to_add' => 'done'
                                     })
    client = build_client(labels: nil)
    @processor.instance_variable_set(:@client, client)

    @processor.send(:update_labels, 42)

    assert_equal 'done', client.edited_labels
  end

  def test_logs_error_on_gitlab_api_failure
    @processor.instance_variable_set(:@project_config, { 'labels_to_remove' => [], 'label_to_add' => nil })
    ensure_gitlab_error_class
    failing_client = Object.new
    failing_client.define_singleton_method(:issue) { |*_args| raise Gitlab::Error::ResponseError, 'API error' }
    @processor.instance_variable_set(:@client, failing_client)

    @processor.send(:update_labels, 42)

    logger = @processor.instance_variable_get(:@logger)

    assert(logger.messages.any? { |m| m.include?('Failed to update labels') })
  end

  private

  def build_client(labels:)
    issue_obj = Struct.new(:labels).new(labels)
    client = Object.new
    client.instance_variable_set(:@issue_obj, issue_obj)
    client.instance_variable_set(:@edited_labels, nil)
    client.define_singleton_method(:issue) { |*_args| @issue_obj }
    client.define_singleton_method(:edit_issue) { |*_args, **kwargs| @edited_labels = kwargs[:labels] }
    client.define_singleton_method(:edited_labels) { @edited_labels }
    client
  end

  def ensure_gitlab_error_class
    Object.const_set(:Gitlab, Module.new) unless defined?(Gitlab)
    Gitlab.const_set(:Error, Module.new) unless defined?(Gitlab::Error)
    return if defined?(Gitlab::Error::ResponseError)

    Gitlab::Error.const_set(:ResponseError, Class.new(StandardError))
  end
end

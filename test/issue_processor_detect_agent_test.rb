# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/issue_processor'

# Tests for IssueProcessor#detect_agent.
class IssueProcessorDetectAgentTest < Minitest::Test
  def setup
    @processor = IssueProcessor.allocate
    @processor.instance_variable_set(:@project_config, {})
    logger = StubLogger.new
    logger.define_singleton_method(:error) { |msg, **_opts| @messages << msg }
    logger.define_singleton_method(:debug) { |msg, **_opts| @messages << msg }
    @processor.instance_variable_set(:@logger, logger)
    @processor.instance_variable_set(:@project_path, 'group/project')
  end

  def test_returns_config_override_when_present
    @processor.instance_variable_set(:@project_config, { 'implementer_agent' => 'custom-impl' })

    Dir.mktmpdir do |dir|
      result = @processor.send(:detect_agent, dir, 'implementer')

      assert_equal 'custom-impl', result
    end
  end

  def test_returns_agent_name_when_project_agent_file_exists
    Dir.mktmpdir do |dir|
      agent_dir = File.join(dir, '.claude', 'agents')
      FileUtils.mkdir_p(agent_dir)
      File.write(File.join(agent_dir, 'implementer.md'), '---\nname: implementer\n---\nCustom agent')

      result = @processor.send(:detect_agent, dir, 'implementer')

      assert_equal 'implementer', result
    end
  end

  def test_injects_default_implementer_agent_when_not_found
    Dir.mktmpdir do |dir|
      result = @processor.send(:detect_agent, dir, 'implementer')

      assert_equal 'implementer', result

      agent_path = File.join(dir, '.claude', 'agents', 'implementer.md')

      assert_path_exists agent_path
      assert_includes File.read(agent_path), 'name: implementer'
    end
  end

  def test_injects_default_test_writer_agent_when_not_found
    Dir.mktmpdir do |dir|
      result = @processor.send(:detect_agent, dir, 'test-writer')

      assert_equal 'test-writer', result

      agent_path = File.join(dir, '.claude', 'agents', 'test-writer.md')

      assert_path_exists agent_path
      assert_includes File.read(agent_path), 'name: test-writer'
    end
  end

  def test_returns_nil_for_unknown_agent_name
    Dir.mktmpdir do |dir|
      result = @processor.send(:detect_agent, dir, 'unknown-agent')

      assert_nil result
    end
  end

  def test_config_override_takes_priority_over_project_file
    @processor.instance_variable_set(:@project_config, { 'test_writer_agent' => 'override-writer' })

    Dir.mktmpdir do |dir|
      agent_dir = File.join(dir, '.claude', 'agents')
      FileUtils.mkdir_p(agent_dir)
      File.write(File.join(agent_dir, 'test-writer.md'), 'project agent')

      result = @processor.send(:detect_agent, dir, 'test-writer')

      assert_equal 'override-writer', result
    end
  end

  def test_config_key_converts_dashes_to_underscores
    @processor.instance_variable_set(:@project_config, { 'test_writer_agent' => 'from-config' })

    Dir.mktmpdir do |dir|
      result = @processor.send(:detect_agent, dir, 'test-writer')

      assert_equal 'from-config', result
    end
  end
end

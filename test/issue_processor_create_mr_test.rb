# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'
require 'autodev/danger_claude_runner'
require 'autodev/issue_processor'

# Tests for IssueProcessor#create_merge_request.
class IssueProcessorCreateMrTest < Minitest::Test
  def setup
    @processor = IssueProcessor.allocate
    logger = StubLogger.new
    logger.define_singleton_method(:error) { |msg, **_opts| @messages << msg }
    logger.define_singleton_method(:debug) { |msg, **_opts| @messages << msg }
    @processor.instance_variable_set(:@logger, logger)
    @processor.instance_variable_set(:@project_path, 'group/project')
    @processor.instance_variable_set(:@project_config, {})
  end

  def test_creates_mr_with_commit_subject_as_title
    with_git_repo('feat: add feature X') do |dir|
      use_create_client
      @processor.send(:create_merge_request, dir, 42, 'b', 'F')

      assert_equal 'feat: add feature X', @last_title
    end
  end

  def test_passes_source_branch_to_api
    with_git_repo('fix: patch') do |dir|
      use_create_client
      @processor.send(:create_merge_request, dir, 7, 'autodev/7-patch', 'P')

      assert_equal 'autodev/7-patch', @last_kwargs[:source_branch]
    end
  end

  def test_reuses_existing_mr_if_found
    with_git_repo('feat: change') do |dir|
      use_list_client([Struct.new(:iid, :web_url).new(99, 'url')])

      assert_equal 99, @processor.send(:create_merge_request, dir, 10, 'b', 'F').iid
    end
  end

  def test_uses_configured_target_branch
    with_git_repo('fix: patch') do |dir|
      @processor.instance_variable_set(:@project_config, { 'target_branch' => 'develop' })
      use_create_client
      @processor.send(:create_merge_request, dir, 7, 'autodev/7-patch', 'P')

      assert_equal 'develop', @last_kwargs[:target_branch]
    end
  end

  def test_mr_description_includes_fixes_reference
    with_git_repo('feat: something') do |dir|
      use_create_client
      @processor.send(:create_merge_request, dir, 55, 'branch', 'T')

      assert_includes @last_kwargs[:description], 'Fixes #55'
    end
  end

  def test_continues_to_create_when_listing_mrs_fails
    with_git_repo('feat: new') do |dir|
      use_failing_list_client

      assert_equal 3, @processor.send(:create_merge_request, dir, 1, 'b', 'T').iid
    end
  end

  private

  def with_git_repo(msg)
    Dir.mktmpdir do |dir|
      init_repo(dir)
      add_file(dir, 'file.rb', 'x', msg)
      yield dir
    end
  end

  def use_create_client
    mr = Struct.new(:iid, :web_url).new(1, 'url')
    ref = self
    client = Object.new
    client.define_singleton_method(:merge_requests) { |*_a, **_k| [] }
    client.define_singleton_method(:create_merge_request) do |_p, title, **kw|
      ref.instance_variable_set(:@last_title, title)
      ref.instance_variable_set(:@last_kwargs, kw)
      mr
    end
    @processor.instance_variable_set(:@client, client)
  end

  def use_list_client(mrs)
    client = Object.new
    client.instance_variable_set(:@mrs, mrs)
    client.define_singleton_method(:merge_requests) { |*_a, **_k| @mrs }
    @processor.instance_variable_set(:@client, client)
  end

  def use_failing_list_client
    Object.const_set(:Gitlab, Module.new) unless defined?(Gitlab)
    Gitlab.const_set(:Error, Module.new) unless defined?(Gitlab::Error)
    Gitlab::Error.const_set(:ResponseError, Class.new(StandardError)) unless defined?(Gitlab::Error::ResponseError)
    mr = Struct.new(:iid, :web_url).new(3, 'url')
    client = Object.new
    client.instance_variable_set(:@mr, mr)
    client.define_singleton_method(:merge_requests) { |*_a, **_k| raise Gitlab::Error::ResponseError, 'x' }
    client.define_singleton_method(:create_merge_request) { |*_a, **_k| @mr }
    @processor.instance_variable_set(:@client, client)
  end

  def init_repo(path)
    system('git', 'init', path, out: File::NULL, err: File::NULL)
    system('git', '-C', path, 'config', 'user.email', 't@t.com')
    system('git', '-C', path, 'config', 'user.name', 'T')
    add_file(path, '.gitkeep', '', 'init')
  end

  def add_file(repo, name, content, message)
    File.write(File.join(repo, name), content)
    system('git', '-C', repo, 'add', name, out: File::NULL, err: File::NULL)
    system('git', '-C', repo, 'commit', '-m', message, out: File::NULL, err: File::NULL)
  end
end

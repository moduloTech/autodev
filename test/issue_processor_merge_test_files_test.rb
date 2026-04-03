# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'
require 'autodev/danger_claude_runner'
require 'autodev/issue_processor'

# Tests for IssueProcessor#merge_test_files.
class IssueProcessorMergeTestFilesTest < Minitest::Test
  def setup
    @processor = IssueProcessor.allocate
    logger = StubLogger.new
    logger.define_singleton_method(:error) { |msg, **_opts| @messages << msg }
    logger.define_singleton_method(:debug) { |msg, **_opts| @messages << msg }
    @processor.instance_variable_set(:@logger, logger)
    @processor.instance_variable_set(:@project_path, 'group/project')
  end

  def test_copies_modified_test_files_from_worktree
    with_two_repos do |test_worktree, work_dir|
      write_and_commit(test_worktree, 'spec/model_spec.rb', 'original spec')
      File.write(File.join(test_worktree, 'spec/model_spec.rb'), 'updated spec')

      @processor.send(:merge_test_files, test_worktree, work_dir)

      assert_equal 'updated spec', File.read(File.join(work_dir, 'spec/model_spec.rb'))
    end
  end

  def test_copies_untracked_test_files_from_worktree
    with_two_repos do |test_worktree, work_dir|
      FileUtils.mkdir_p(File.join(test_worktree, 'test'))
      File.write(File.join(test_worktree, 'test/new_test.rb'), 'new test')

      @processor.send(:merge_test_files, test_worktree, work_dir)

      assert_equal 'new test', File.read(File.join(work_dir, 'test/new_test.rb'))
    end
  end

  def test_logs_no_changes_when_worktree_is_clean
    with_two_repos do |test_worktree, work_dir|
      @processor.send(:merge_test_files, test_worktree, work_dir)

      logger = @processor.instance_variable_get(:@logger)

      assert(logger.messages.any? { |m| m.include?('no changes') })
    end
  end

  def test_creates_nested_directories_in_work_dir
    with_two_repos do |test_worktree, work_dir|
      FileUtils.mkdir_p(File.join(test_worktree, 'spec/models/concerns'))
      File.write(File.join(test_worktree, 'spec/models/concerns/taggable_spec.rb'), 'concern spec')

      @processor.send(:merge_test_files, test_worktree, work_dir)

      assert_equal 'concern spec', File.read(File.join(work_dir, 'spec/models/concerns/taggable_spec.rb'))
    end
  end

  def test_logs_merged_file_names
    with_two_repos do |test_worktree, work_dir|
      File.write(File.join(test_worktree, 'new_spec.rb'), 'spec content')

      @processor.send(:merge_test_files, test_worktree, work_dir)

      logger = @processor.instance_variable_get(:@logger)

      assert(logger.messages.any? { |m| m.include?('new_spec.rb') })
    end
  end

  private

  def with_two_repos
    Dir.mktmpdir do |base|
      test_worktree = File.join(base, 'test_wt')
      work_dir = File.join(base, 'main')
      setup_git_repo(test_worktree)
      setup_git_repo(work_dir)
      yield test_worktree, work_dir
    end
  end

  def setup_git_repo(path)
    FileUtils.mkdir_p(path)
    system('git', 'init', path, out: File::NULL, err: File::NULL)
    system('git', '-C', path, 'config', 'user.email', 'test@test.com')
    system('git', '-C', path, 'config', 'user.name', 'Test')
    File.write(File.join(path, '.gitkeep'), '')
    system('git', '-C', path, 'add', '.gitkeep')
    system('git', '-C', path, 'commit', '-m', 'init', out: File::NULL, err: File::NULL)
  end

  def write_and_commit(repo, relative_path, content)
    full_path = File.join(repo, relative_path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, content)
    system('git', '-C', repo, 'add', relative_path)
    system('git', '-C', repo, 'commit', '-m', "add #{relative_path}", out: File::NULL, err: File::NULL)
  end
end

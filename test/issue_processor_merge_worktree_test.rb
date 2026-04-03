# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'
require 'autodev/danger_claude_runner'
require 'autodev/issue_processor'

# Tests for IssueProcessor#merge_worktree_files.
class IssueProcessorMergeWorktreeTest < Minitest::Test
  def setup
    @processor = IssueProcessor.allocate
    logger = StubLogger.new
    logger.define_singleton_method(:error) { |msg, **_opts| @messages << msg }
    logger.define_singleton_method(:debug) { |msg, **_opts| @messages << msg }
    @processor.instance_variable_set(:@logger, logger)
    @processor.instance_variable_set(:@project_path, 'group/project')
  end

  def test_copies_modified_files_from_worktree_to_work_dir
    with_two_repos do |worktree, work_dir|
      write_and_commit(worktree, 'app/model.rb', 'original')
      write_and_commit(work_dir, 'app/model.rb', 'original')
      File.write(File.join(worktree, 'app/model.rb'), 'modified')

      @processor.send(:merge_worktree_files, worktree, work_dir, 'task-1')

      assert_equal 'modified', File.read(File.join(work_dir, 'app/model.rb'))
    end
  end

  def test_copies_untracked_files_from_worktree
    with_two_repos do |worktree, work_dir|
      FileUtils.mkdir_p(File.join(worktree, 'lib'))
      File.write(File.join(worktree, 'lib/new_file.rb'), 'new content')

      @processor.send(:merge_worktree_files, worktree, work_dir, 'task-1')

      assert_equal 'new content', File.read(File.join(work_dir, 'lib/new_file.rb'))
    end
  end

  def test_creates_destination_directories_as_needed
    with_two_repos do |worktree, work_dir|
      FileUtils.mkdir_p(File.join(worktree, 'deep/nested/dir'))
      File.write(File.join(worktree, 'deep/nested/dir/file.rb'), 'deep content')

      @processor.send(:merge_worktree_files, worktree, work_dir, 'task-1')

      assert_equal 'deep content', File.read(File.join(work_dir, 'deep/nested/dir/file.rb'))
    end
  end

  def test_logs_no_changes_when_worktree_is_clean
    with_two_repos do |worktree, work_dir|
      @processor.send(:merge_worktree_files, worktree, work_dir, 'empty-task')

      logger = @processor.instance_variable_get(:@logger)

      assert(logger.messages.any? { |m| m.include?('no changes') })
    end
  end

  def test_merges_both_modified_and_untracked_files
    with_two_repos do |worktree, work_dir|
      write_and_commit(worktree, 'existing.rb', 'old')
      write_and_commit(work_dir, 'existing.rb', 'old')
      File.write(File.join(worktree, 'existing.rb'), 'updated')
      File.write(File.join(worktree, 'brand_new.rb'), 'fresh')

      @processor.send(:merge_worktree_files, worktree, work_dir, 'mixed-task')

      assert_equal 'updated', File.read(File.join(work_dir, 'existing.rb'))
      assert_equal 'fresh', File.read(File.join(work_dir, 'brand_new.rb'))
    end
  end

  private

  def with_two_repos
    Dir.mktmpdir do |base|
      worktree = File.join(base, 'worktree')
      work_dir = File.join(base, 'main')
      setup_git_repo(worktree)
      setup_git_repo(work_dir)
      yield worktree, work_dir
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

# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'
require 'autodev/repo_operations'

# Verifies the pre-push size guard (check_push_size!) that fails fast with an
# actionable message when a commit would push a pack over GitLab's 50 MiB limit
# (Autodev task #21/#20 — the "pack exceeds maximum allowed size" rejection).
#
# The object-range logic (which objects a push would actually send) runs against
# a real bare origin + shallow clone, since that's the part that's easy to get
# wrong; the threshold decision + message are exercised with fabricated sizes so
# the suite never has to write a 50 MiB file.
class RepoOperationsPushSizeTest < Minitest::Test
  class Harness
    include ShellHelpers
    include RepoOperations

    def initialize(logger:, project_config: {})
      @logger = logger
      @project_config = project_config
    end

    def log(msg) = @logger.info(msg)
    def log_error(msg) = @logger.error(msg)
  end

  def setup
    @tmpdir = Dir.mktmpdir('push_size_test')
    @bare = File.join(@tmpdir, 'origin.git')
    @work_dir = File.join(@tmpdir, 'clone')
    seed_bare_origin
    @harness = Harness.new(logger: StubLogger.new)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # --- object range (real git) ---------------------------------------------

  def test_push_object_sizes_lists_new_blob_and_excludes_base
    clone_and_commit('app/new.rb', "puts 1\n")

    paths = @harness.send(:push_object_sizes, @work_dir).map { |_size, path| path }

    assert_includes paths, 'app/new.rb', 'the newly committed blob is part of the push'
    refute_includes paths, 'base.txt', 'a blob already on origin must not count toward the push'
  end

  def test_push_object_sizes_empty_once_commit_is_pushed
    clone_and_commit('x.txt', "hi\n")
    system('git', 'push', 'origin', 'feat', chdir: @work_dir, out: File::NULL, err: File::NULL)
    # Establish origin/feat the same way MrFixer#fetch_and_checkout does, since a
    # shallow single-branch clone's default refspec would not fetch it.
    system('git', 'fetch', 'origin', '+refs/heads/feat:refs/remotes/origin/feat',
           chdir: @work_dir, out: File::NULL, err: File::NULL)

    assert_empty @harness.send(:push_object_sizes, @work_dir),
                 'an already-pushed commit contributes nothing to the next push (re-push case)'
  end

  # --- threshold decision + message (fabricated sizes) ---------------------

  def test_aborts_when_new_objects_exceed_limit
    over = RepoOperations::MAX_PUSH_PACK_BYTES + 1
    @harness.define_singleton_method(:push_object_sizes) { |_wd| [[over, 'db/dump.sql'], [10, 'app/a.rb']] }

    err = assert_raises(ImplementationError) { @harness.send(:check_push_size!, @work_dir) }
    assert_match 'Push aborted', err.message
    assert_match 'db/dump.sql', err.message
  end

  def test_passes_when_under_limit
    @harness.define_singleton_method(:push_object_sizes) { |_wd| [[1024, 'app/a.rb'], [2048, 'app/b.rb']] }

    assert_nil @harness.send(:check_push_size!, @work_dir)
  end

  def test_abort_message_lists_largest_files_first
    over = RepoOperations::MAX_PUSH_PACK_BYTES
    @harness.define_singleton_method(:push_object_sizes) do |_wd|
      [[1, 'small.bin'], [over, 'huge.bin'], [over / 2, 'mid.bin']] # deliberately unsorted
    end

    err = assert_raises(ImplementationError) { @harness.send(:check_push_size!, @work_dir) }
    assert_operator err.message.index('huge.bin'), :<, err.message.index('mid.bin')
  end

  # --- probe robustness -----------------------------------------------------

  def test_probe_failure_is_swallowed_so_push_proceeds
    @harness.define_singleton_method(:collect_objects) { |*_args| raise GitError, 'boom' }

    assert_empty @harness.send(:push_object_sizes, @work_dir)
  end

  private

  def seed_bare_origin
    seed = File.join(@tmpdir, 'seed')
    git_init(seed)
    write_and_commit(seed, 'base.txt', "base\n", 'init')
    system('git', 'clone', '--bare', seed, @bare, out: File::NULL, err: File::NULL)
  end

  def clone_and_commit(path, content)
    system('git', 'clone', '--depth', '1', '--branch', 'main', @bare, @work_dir,
           out: File::NULL, err: File::NULL)
    configure_identity(@work_dir)
    system('git', 'checkout', '-b', 'feat', chdir: @work_dir, out: File::NULL, err: File::NULL)
    write_and_commit(@work_dir, path, content, 'work')
  end

  def git_init(dir)
    FileUtils.mkdir_p(dir)
    system('git', 'init', chdir: dir, out: File::NULL, err: File::NULL)
    configure_identity(dir)
    system('git', 'checkout', '-b', 'main', chdir: dir, out: File::NULL, err: File::NULL)
  end

  def configure_identity(dir)
    system('git', 'config', 'user.email', 'test@example', chdir: dir, out: File::NULL, err: File::NULL)
    system('git', 'config', 'user.name', 'Test', chdir: dir, out: File::NULL, err: File::NULL)
  end

  def write_and_commit(dir, path, content, message)
    full = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
    system('git', 'add', path, chdir: dir, out: File::NULL, err: File::NULL)
    system('git', 'commit', '-m', message, chdir: dir, out: File::NULL, err: File::NULL)
  end
end

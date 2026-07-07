# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'
require 'autodev/repo_operations'

# Regression (task #33): re-implementing an EXISTING branch reuses it, rebases it
# on the (meanwhile-advanced) target, and pushes. The rebase rewrites history, so
# the previously-delivered remote commit is no longer an ancestor of the pushed
# tip. A bare `git push --force-with-lease` implies `--force-if-includes`
# (git >= 2.30), which then rejects the push with "stale info" — leaving the
# recette-KO reentry (#32) stuck in `error`. The force push must succeed here (we
# deliberately overwrite our own prior delivery) while still leasing on the
# remote value we fetched.
class RepoOperationsForcePushTest < Minitest::Test
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
    @tmpdir = Dir.mktmpdir('force_push_test')
    @bare = File.join(@tmpdir, 'origin.git')
    @work_dir = File.join(@tmpdir, 'clone')
    seed_bare_origin_with_stale_branch
    @harness = Harness.new(logger: StubLogger.new)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_force_push_succeeds_after_rebasing_existing_branch
    prepare_reworked_branch
    local_head = rev_parse(@work_dir, 'HEAD')

    @harness.send(:push_with_lease_fallback, @work_dir, 'feat')

    assert_equal local_head, remote_ref_sha('feat'),
                 'the reworked branch must overwrite the stale remote delivery'
  end

  # The lease must still protect against a concurrent push: if the remote moved
  # since our fetch, the force push must be refused rather than clobbering it.
  def test_force_push_refuses_when_remote_moved_since_fetch
    prepare_reworked_branch
    push_unrelated_commit_to_remote_feat

    assert_raises(GitError) { @harness.send(:push_with_lease_fallback, @work_dir, 'feat') }
  end

  private

  def prepare_reworked_branch
    # `--single-branch` mirrors autodev's `--depth 1` clone (which implies it):
    # origin/<feat> then exists ONLY via the one-off fetch below, which is what
    # makes the implicit --force-if-includes reject the post-rebase push.
    system('git', 'clone', '--single-branch', '--branch', 'main', @bare, @work_dir,
           out: File::NULL, err: File::NULL)
    configure_identity(@work_dir)
    run_git(@work_dir, 'fetch', 'origin', '+refs/heads/feat:refs/remotes/origin/feat')
    run_git(@work_dir, 'checkout', '-b', 'feat', 'origin/feat')
    run_git(@work_dir, 'rebase', 'origin/main')
    write_and_commit(@work_dir, 'f.txt', "reworked\n", 'rework after recette KO')
  end

  # Simulate someone pushing to the remote feat branch after our fetch, so the
  # leased value is now stale for real.
  def push_unrelated_commit_to_remote_feat
    other = File.join(@tmpdir, 'other')
    system('git', 'clone', '--branch', 'feat', @bare, other, out: File::NULL, err: File::NULL)
    configure_identity(other)
    write_and_commit(other, 'other.txt', "concurrent\n", 'concurrent change')
    system('git', 'push', 'origin', 'feat', chdir: other, out: File::NULL, err: File::NULL)
  end

  def seed_bare_origin_with_stale_branch
    seed = File.join(@tmpdir, 'seed')
    git_init(seed)
    write_and_commit(seed, 'base.txt', "base\n", 'init')
    system('git', 'checkout', '-b', 'feat', chdir: seed, out: File::NULL, err: File::NULL)
    write_and_commit(seed, 'delivery.txt', "delivered\n", 'autodev delivery')
    system('git', 'checkout', 'main', chdir: seed, out: File::NULL, err: File::NULL)
    write_and_commit(seed, 'base.txt', "base\nadvanced\n", 'target advances')
    system('git', 'clone', '--bare', seed, @bare, out: File::NULL, err: File::NULL)
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
    File.write(File.join(dir, path), content)
    system('git', 'add', path, chdir: dir, out: File::NULL, err: File::NULL)
    system('git', 'commit', '-m', message, chdir: dir, out: File::NULL, err: File::NULL)
  end

  def run_git(dir, *args)
    system('git', *args, chdir: dir, out: File::NULL, err: File::NULL) ||
      raise("git #{args.join(' ')} failed")
  end

  def rev_parse(dir, ref)
    out, = Open3.capture2('git', 'rev-parse', ref, chdir: dir)
    out.strip
  end

  def remote_ref_sha(branch)
    out, = Open3.capture2('git', 'ls-remote', @bare, "refs/heads/#{branch}")
    out.split("\t").first.to_s.strip
  end
end

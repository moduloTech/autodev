# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'
require 'autodev/repo_rebaser'

# Verifies the rebase-on-target flow used before every write action
# (implementing, fixing discussions, fixing pipeline). Builds an actual git
# repo on disk so the rebase / fetch / log commands run for real — stubbing
# would defeat the purpose (the goal is to catch regressions in the git
# command sequence, not just the Ruby control flow).
class RepoRebaserTest < Minitest::Test
  # Host class exposing the private RepoRebaser methods + the shell + repo
  # plumbing they expect (run_cmd_status, log, log_error, default_branch,
  # push_with_lease_fallback, danger_claude_prompt).
  class Harness
    include ShellHelpers
    include RepoRebaser

    attr_accessor :pushed, :claude_invocations, :force_conflict_resolution

    def initialize(project_config:, logger:)
      @project_config = project_config
      @logger = logger
      @pushed = []
      @claude_invocations = []
      @force_conflict_resolution = nil
    end

    # Stubs so we don't actually push or invoke danger-claude in tests.
    def push_with_lease_fallback(work_dir, branch, upstream: false)
      @pushed << { work_dir: work_dir, branch: branch, upstream: upstream }
    end

    def danger_claude_prompt(work_dir, prompt, **_opts)
      @claude_invocations << { work_dir: work_dir, prompt: prompt }
      @force_conflict_resolution&.call(work_dir)
    end

    def default_branch(_work_dir)
      'main'
    end

    def log(msg) = @logger.info(msg)
    def log_error(msg) = @logger.error(msg)
  end

  def setup
    @tmpdir = Dir.mktmpdir('rebaser_test')
    @bare = File.join(@tmpdir, 'origin.git')
    @work_dir = File.join(@tmpdir, 'clone')
    setup_bare_with_diverging_branches
    @logger = StubLogger.new
    @harness = Harness.new(project_config: { 'target_branch' => 'main' }, logger: @logger)
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  def test_no_op_when_target_has_no_new_commits
    clone_branch('main')
    # No divergence: branch == main HEAD after clone

    verdict = @harness.send(:rebase_branch_on_target, @work_dir, 'main')

    assert_equal :no_op, verdict
    assert_empty @harness.pushed
  end

  def test_clean_rebase_when_target_advanced_and_no_conflict
    clone_branch('feature_clean')

    verdict = @harness.send(:rebase_branch_on_target, @work_dir, 'feature_clean')

    assert_equal :rebased, verdict
    refute_empty @harness.pushed
  end

  def test_conflict_invokes_claude_and_continues_when_resolved
    clone_branch('feature_conflict')
    @harness.force_conflict_resolution = lambda do |work_dir|
      # Simulate claude resolving the conflict: take the branch version and stage it.
      File.write(File.join(work_dir, 'README.md'), "branch-version\n")
      system('git', 'add', 'README.md', chdir: work_dir, out: File::NULL, err: File::NULL)
    end

    verdict = @harness.send(:rebase_branch_on_target, @work_dir, 'feature_conflict')

    assert_equal :rebased, verdict
    assert_equal 1, @harness.claude_invocations.size
  end

  def test_conflict_aborts_when_claude_does_not_resolve
    clone_branch('feature_conflict')
    @harness.force_conflict_resolution = ->(_) {} # claude does nothing

    verdict = @harness.send(:rebase_branch_on_target, @work_dir, 'feature_conflict')

    assert_equal :failed, verdict
    assert_empty @harness.pushed
  end

  def test_conflict_abort_leaves_branch_in_pre_rebase_state
    clone_branch('feature_conflict')
    pre_head = head_sha(@work_dir)
    @harness.force_conflict_resolution = ->(_) {}

    @harness.send(:rebase_branch_on_target, @work_dir, 'feature_conflict')

    assert_equal pre_head, head_sha(@work_dir)
  end

  private

  def setup_bare_with_diverging_branches
    seed = File.join(@tmpdir, 'seed')
    git_init(seed)
    write_and_commit(seed, 'README.md', "initial\n", 'init')
    write_and_commit(seed, 'main_only.txt', "main\n", 'main moves ahead')
    create_clean_branch(seed)
    create_conflict_branch(seed)
    system('git', 'clone', '--bare', seed, @bare, out: File::NULL, err: File::NULL)
  end

  def create_clean_branch(seed)
    system('git', 'checkout', '-b', 'feature_clean', 'HEAD~1', chdir: seed,
                                                               out: File::NULL, err: File::NULL)
    write_and_commit(seed, 'feature.txt', "feat\n", 'feature edit')
  end

  # feature_conflict edits README.md on a different value than main does, on
  # the same line range — a real merge conflict.
  def create_conflict_branch(seed)
    system('git', 'checkout', 'main', chdir: seed, out: File::NULL, err: File::NULL)
    write_and_commit(seed, 'README.md', "main-version\n", 'main edits readme')
    system('git', 'checkout', '-b', 'feature_conflict', 'HEAD~2', chdir: seed,
                                                                  out: File::NULL, err: File::NULL)
    write_and_commit(seed, 'README.md', "branch-version\n", 'branch edits readme')
  end

  def clone_branch(branch)
    system('git', 'clone', '--depth', '1', '--branch', branch, @bare, @work_dir,
           out: File::NULL, err: File::NULL)
  end

  def git_init(dir)
    FileUtils.mkdir_p(dir)
    %w[init].each { |cmd| system('git', cmd, chdir: dir, out: File::NULL, err: File::NULL) }
    system('git', 'config', 'user.email', 'test@example', chdir: dir, out: File::NULL, err: File::NULL)
    system('git', 'config', 'user.name', 'Test', chdir: dir, out: File::NULL, err: File::NULL)
    system('git', 'checkout', '-b', 'main', chdir: dir, out: File::NULL, err: File::NULL)
  end

  def write_and_commit(dir, path, content, message)
    File.write(File.join(dir, path), content)
    system('git', 'add', path, chdir: dir, out: File::NULL, err: File::NULL)
    system('git', 'commit', '-m', message, chdir: dir, out: File::NULL, err: File::NULL)
  end

  def head_sha(dir)
    `git -C #{dir} rev-parse HEAD`.strip
  end
end

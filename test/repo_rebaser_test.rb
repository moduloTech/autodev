# frozen_string_literal: true

require_relative 'test_helper'
require 'open3'
require 'autodev/repo_rebaser'

# Verifies the rebase-on-target flow used before every write action
# (implementing, fixing discussions, fixing pipeline). Builds an actual git
# repo on disk so the rebase / fetch / log commands run for real — stubbing
# would defeat the purpose (the goal is to catch regressions in the git
# command sequence, not just the Ruby control flow).
#
# `base:` is handed in since Autodev #91: which branch this branch rebases onto
# is `TargetBranch`'s answer, not this module's, and it is a required keyword so
# that a caller cannot omit having asked.
class RepoRebaserTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  # Host class exposing the private RepoRebaser methods + the shell + repo
  # plumbing they expect (run_cmd_status, log, log_error,
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

    verdict = @harness.send(:rebase_branch_on_target, @work_dir, 'main', base: 'main')

    assert_equal :no_op, verdict
    assert_empty @harness.pushed
  end

  def test_clean_rebase_when_target_advanced_and_no_conflict
    clone_branch('feature_clean')

    verdict = @harness.send(:rebase_branch_on_target, @work_dir, 'feature_clean', base: 'main')

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

    verdict = @harness.send(:rebase_branch_on_target, @work_dir, 'feature_conflict', base: 'main')

    assert_equal :rebased, verdict
    assert_equal 1, @harness.claude_invocations.size
  end

  # Autodev #138: a conflict danger-claude did not resolve is no longer the
  # symbol `:failed`, which all three callers discarded before working on the
  # stale base. It raises, naming what a human has to resolve.
  def test_conflict_raises_when_claude_does_not_resolve # rubocop:disable Minitest/MultipleAssertions
    clone_branch('feature_conflict')
    @harness.force_conflict_resolution = ->(_) {} # claude does nothing

    error = assert_raises(RebaseConflictError) do
      @harness.send(:rebase_branch_on_target, @work_dir, 'feature_conflict', base: 'main')
    end

    assert_equal ['README.md'], error.files
    assert_equal 'main', error.base
    assert_equal 'feature_conflict', error.branch
    assert_empty @harness.pushed
    refute rebase_in_progress?(@work_dir), 'the rebase must be aborted before the error leaves'
  end

  # Regression: when danger-claude itself failed (e.g. session limit) inside
  # resolve_conflicts_then_continue, the raise propagated up uncaught, leaving
  # the work tree in a half-rebased state and crashing PipelineFixer mid-flight.
  # Observed on Powerpanne issue #15643 (2026-06-02) with v0.15.0.
  #
  # The abort stays; what changed with Autodev #138 is what follows it. A crash
  # used to answer `:failed` and the work went on, on the stale base. It now
  # travels on as itself — not as a conflict verdict, since a tool that did not
  # run said nothing about the conflict — to the boundary's own handler.
  def test_claude_crash_aborts_rebase_and_travels_as_itself
    clone_branch('feature_conflict')
    @harness.force_conflict_resolution = ->(_) { raise ImplementationError, 'claude crashed' }

    assert_raises(ImplementationError) do
      @harness.send(:rebase_branch_on_target, @work_dir, 'feature_conflict', base: 'main')
    end
    refute rebase_in_progress?(@work_dir), 'rebase should be aborted after claude crash'
  end

  # Autodev #138: the push after a resolved conflict used to sit under the
  # resolution's `rescue StandardError`, so a push GitLab refused read as a failed
  # rebase and the work went on. It now propagates, as after a clean rebase.
  def test_a_push_that_fails_after_a_resolved_conflict_propagates
    clone_branch('feature_conflict')
    @harness.force_conflict_resolution = lambda do |work_dir|
      File.write(File.join(work_dir, 'README.md'), "branch-version\n")
      system('git', 'add', 'README.md', chdir: work_dir, out: File::NULL, err: File::NULL)
    end
    @harness.define_singleton_method(:push_with_lease_fallback) { |*, **| raise GitError, 'push refused' }

    assert_raises(GitError) do
      @harness.send(:rebase_branch_on_target, @work_dir, 'feature_conflict', base: 'main')
    end
  end

  # Which files a human is told to resolve (Autodev #138): the ones git still
  # lists as unmerged when it refuses to continue — here a *later* commit's — and
  # not the ones danger-claude was first asked about, which it resolved. Read
  # before the abort, which empties the answer.
  def test_the_files_named_are_the_ones_still_unmerged_when_git_refuses
    clone_branch('feature_two_conflicts')
    @harness.force_conflict_resolution = lambda do |work_dir|
      File.write(File.join(work_dir, 'README.md'), "branch-version\n")
      system('git', 'add', 'README.md', chdir: work_dir, out: File::NULL, err: File::NULL)
    end

    error = assert_raises(RebaseConflictError) do
      @harness.send(:rebase_branch_on_target, @work_dir, 'feature_two_conflicts', base: 'main')
    end

    assert_equal ['main_only.txt'], error.files
  end

  # The other half: git refuses to continue with nothing left unmerged (every
  # conflict resolved and staged, `--continue` refused anyway). The files named are
  # then the ones the replay stopped on before danger-claude ran — read at that
  # moment, since nothing later can say.
  def test_the_files_the_replay_stopped_on_are_named_when_nothing_is_left_unmerged
    clone_branch('feature_conflict')
    @harness.force_conflict_resolution = lambda do |work_dir|
      File.write(File.join(work_dir, 'README.md'), "branch-version\n")
      system('git', 'add', 'README.md', chdir: work_dir, out: File::NULL, err: File::NULL)
    end
    refuse_continue(@harness)

    error = assert_raises(RebaseConflictError) do
      @harness.send(:rebase_branch_on_target, @work_dir, 'feature_conflict', base: 'main')
    end

    assert_equal ['README.md'], error.files
  end

  # The production clone is `--depth 1` over https, and that transport honours the
  # depth where a plain path does not — so these go through `file://`. The branch
  # then has no parent, and deepening the target alone never reaches the fork
  # point: git replayed the tip as a root commit and reported every file the
  # target had changed as a conflict (README.md here, which the branch never
  # touched). Deepening both sides finds the fork, and the rebase is clean.
  def test_a_shallow_clone_rebases_without_inventing_conflicts
    clone_branch('feature_clean', shallow: true)

    verdict = @harness.send(:rebase_branch_on_target, @work_dir, 'feature_clean', base: 'main')

    assert_equal :rebased, verdict
    assert_empty @harness.claude_invocations, 'a clean rebase was handed to danger-claude as a conflict'
  end

  # Same, with a fork point further back than one deepening round reaches: the
  # rounds go on until git finds it.
  def test_the_deepening_goes_on_until_the_fork_point_is_reached
    @harness.define_singleton_method(:deepen_step) { 1 }
    clone_branch('feature_clean', shallow: true)

    assert_equal :rebased, @harness.send(:rebase_branch_on_target, @work_dir, 'feature_clean', base: 'main')
  end

  # No merge base even with the whole history: not a conflict a human can resolve
  # from a list of files, so not a hand-back.
  def test_unrelated_histories_are_a_git_error_not_a_conflict
    push_orphan_branch('orphan')
    clone_branch('orphan', shallow: true)

    assert_raises(GitError) do
      @harness.send(:rebase_branch_on_target, @work_dir, 'orphan', base: 'main')
    end
    assert_empty @harness.claude_invocations
  end

  # danger-claude ran `git rebase --continue` itself, against the prompt: ours
  # then fails with "no rebase in progress", on a branch that is rebased. That is
  # a finished rebase, not a conflict.
  def test_a_rebase_danger_claude_finished_itself_is_a_rebase
    clone_branch('feature_conflict')
    @harness.force_conflict_resolution = lambda do |work_dir|
      File.write(File.join(work_dir, 'README.md'), "branch-version\n")
      system('git', 'add', 'README.md', chdir: work_dir, out: File::NULL, err: File::NULL)
      system({ 'GIT_EDITOR' => 'true' }, 'git', 'rebase', '--continue', chdir: work_dir, out: File::NULL,
                                                                        err: File::NULL)
    end

    assert_equal :rebased, @harness.send(:rebase_branch_on_target, @work_dir, 'feature_conflict', base: 'main')
    refute_empty @harness.pushed
  end

  # Not an outage: the family's answer — leave the row, re-read next cycle — is the
  # loop a refused rebase must not enter (Autodev #138).
  def test_a_failed_rebase_is_not_a_member_of_the_api_unavailable_family
    refute_kind_of ApiUnavailableError, RebaseConflictError.new(branch: 'b', base: 'main', files: [])
  end

  def test_rate_limit_in_conflict_resolution_propagates
    clone_branch('feature_conflict')
    @harness.force_conflict_resolution = lambda do |_|
      raise RateLimitError.new('limit hit', reset_time: Time.now + 60)
    end

    assert_raises(RateLimitError) do
      @harness.send(:rebase_branch_on_target, @work_dir, 'feature_conflict', base: 'main')
    end
    refute rebase_in_progress?(@work_dir), 'rebase should be aborted before re-raising rate limit'
  end

  # Autodev #91: a base that is not on the remote is not a base. Every git
  # question here answers "nothing found" for a missing ref, which is exactly what
  # "already up to date" looks like — so a merge request whose target branch had
  # been deleted was silently not rebased, and the write action that followed ran
  # against a tree measured against nothing.
  def test_a_base_that_is_not_on_the_remote_aborts_instead_of_reading_as_up_to_date # rubocop:disable Minitest/MultipleAssertions
    clone_branch('feature_clean')

    error = assert_raises(MissingTargetBranchError) do
      @harness.send(:rebase_branch_on_target, @work_dir, 'feature_clean', base: 'deleted-last-week')
    end

    assert_equal 'deleted-last-week', error.branch
    assert_empty @harness.pushed
    refute_includes error.message, 'GitLab did not answer',
                    'GitLab answered perfectly well; the branch it named is gone'
  end

  # And it travels as one: every boundary that already knows "this unit of work
  # concluded nothing" handles it with no new rescue clause.
  def test_a_missing_base_is_a_member_of_the_api_unavailable_family
    assert_kind_of ApiUnavailableError, MissingTargetBranchError.new('x', 'gone')
  end

  # The review round's addition (constat 3): a boundary is entitled to *bound* the
  # wait on a base that is gone, and only on that. "Deleted upstream" needs a human
  # and will never resolve itself; "the fetch did not complete" is an outage
  # wearing the same exception, and bounding it would hand a healthy request back
  # to its author over a flapping network. So the remote is asked which of the two
  # happened, once, on the path that is about to raise anyway.
  def test_a_base_the_remote_answers_it_does_not_have_is_evidence
    clone_branch('feature_clean')

    error = assert_raises(MissingTargetBranchError) do
      @harness.send(:ensure_base_available!, @work_dir, 'deleted-last-week')
    end

    assert_predicate error, :confirmed?, 'the remote answered; that is evidence the branch is gone'
  end

  # The remote unreachable: same exception, no evidence, no bound. Simulated by
  # taking the origin away after the clone, which is what a network partition looks
  # like to `ls-remote`.
  def test_a_remote_that_cannot_be_asked_is_not_evidence
    clone_branch('feature_clean')
    FileUtils.rm_rf(@bare)

    error = assert_raises(MissingTargetBranchError) do
      @harness.send(:ensure_base_available!, @work_dir, 'main')
    end

    refute_predicate error, :confirmed?, 'nothing established that the branch is gone'
  end

  # And the third case, which is neither: the remote has the branch, so the fetch
  # is what did not land. Also not evidence.
  def test_a_fetch_that_did_not_land_is_not_evidence
    clone_branch('feature_clean')
    system('git', 'update-ref', '-d', 'refs/remotes/origin/main', chdir: @work_dir,
                                                                  out: File::NULL, err: File::NULL)

    error = assert_raises(MissingTargetBranchError) do
      @harness.send(:ensure_base_available!, @work_dir, 'main')
    end

    refute_predicate error, :confirmed?, 'the remote still carries the branch'
  end

  def test_conflict_abort_leaves_branch_in_pre_rebase_state
    clone_branch('feature_conflict')
    pre_head = head_sha(@work_dir)
    @harness.force_conflict_resolution = ->(_) {}

    assert_raises(RebaseConflictError) do
      @harness.send(:rebase_branch_on_target, @work_dir, 'feature_conflict', base: 'main')
    end

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
    create_two_conflicts_branch(seed)
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

  # feature_two_conflicts: feature_conflict's README commit, then a second commit
  # creating `main_only.txt`, which main also created with other content. The
  # replay stops on README first and, once that is resolved, on main_only.txt.
  def create_two_conflicts_branch(seed)
    system('git', 'checkout', '-b', 'feature_two_conflicts', 'feature_conflict', chdir: seed,
                                                                                 out: File::NULL, err: File::NULL)
    write_and_commit(seed, 'main_only.txt', "branch-only\n", 'branch creates main_only')
  end

  # `git rebase --continue` answers non-zero whatever the tree holds; every other
  # git command runs for real.
  def refuse_continue(harness)
    harness.define_singleton_method(:run_cmd_status) do |cmd, **opts|
      next ['', 'refused', false] if cmd == %w[git rebase --continue]

      super(cmd, **opts)
    end
  end

  # A plain path ignores `--depth` (git copies the objects); `file://` honours it,
  # like the https clone production makes.
  def clone_branch(branch, shallow: false)
    source = shallow ? "file://#{@bare}" : @bare
    system('git', 'clone', '--depth', '1', '--branch', branch, source, @work_dir,
           out: File::NULL, err: File::NULL)
  end

  # A branch sharing no commit with main.
  def push_orphan_branch(name)
    other = File.join(@tmpdir, 'orphan_seed')
    git_init(other)
    write_and_commit(other, 'alone.txt', "alone\n", 'unrelated root')
    system('git', 'push', @bare, "main:refs/heads/#{name}", chdir: other, out: File::NULL, err: File::NULL)
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

  def rebase_in_progress?(dir)
    File.exist?(File.join(dir, '.git', 'rebase-apply')) ||
      File.exist?(File.join(dir, '.git', 'rebase-merge'))
  end
end

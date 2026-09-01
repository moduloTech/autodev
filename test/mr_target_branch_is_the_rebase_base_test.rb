# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'open3'
require 'autodev/danger_claude_runner'
require 'autodev/mr_fixer'
require 'autodev/pipeline_monitor'
require 'autodev/issue_processor'

# Autodev #91 — an existing merge request rebases onto *its own* target branch.
#
# "Which branch does this branch rebase onto" was asked at five places and
# answered three ways: `@project_config['target_branch'] || default_branch` (the
# rebaser, the MR creation, `verify_changes`, the clone), `default_branch` alone
# (`build_fix_env`, which feeds the hunk quoted to danger-claude), and — read by
# nobody — the target the merge request itself carries.
#
# Two questions had been confused. "Where do this project's **new** merge
# requests go" is a property of the project and the config answers it correctly.
# "Where does **this** merge request go" is a property of that merge request,
# recorded on GitLab when it was created. They are equal at birth, because
# `MrManager#create_merge_request` writes the config's value into the MR — and
# they diverge the moment the config moves while merge requests are open.
#
# Measured: PowerPanne moved from `staging` to `master` on 25/08/2026 with merge
# requests open. On 01/09, 83 open MRs still targeted `staging`, 64 of them on an
# autodev branch, and `master` carried 49 commits `staging` did not have. The one
# live autodev line carrying an MR (#10837, parked in `needs_clarification`)
# targeted `staging` while the config said `master`. Any write action on such a
# line rebased the branch onto `origin/master` and force-pushed it, while GitLab
# kept computing the MR's diff against `staging`: the MR then shows commits and
# files it never touched, and every discussion thread's position is anchored on
# the previous diff.
#
# This file pins the outcome on a real git repository, because the defect is in
# the git command sequence, not in the Ruby control flow. The layout is
# PowerPanne's: `staging` is the MR's target, `master` is the config's, and both
# have moved since the autodev branch was cut.
module RebaseBaseFixtures
  FakeNote = Struct.new(:resolvable, :resolved, :body, :author, :created_at, :position)
  FakeDiscussion = Struct.new(:id, :notes)
  FakeIssuePayload = Struct.new(:iid, :title, :description, :state)
  FakeMr = Struct.new(:iid, :state, :target_branch, :head_pipeline)
  FakePosition = Struct.new(:new_path, :new_line, :old_line)

  # `Gitlab::Error::ResponseError` builds its message from the real HTTP
  # response; this is the minimum surface it reads. Duplicated rather than
  # shared because every test file has to pass run on its own (Autodev #64).
  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  def api_error
    Gitlab::Error::ResponseError.new(
      FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/x'))
    )
  end

  # Behaves like Gitlab::PaginatedResponse.
  class FakePaginated
    def initialize(items) = @items = items
    def auto_paginate = @items
  end

  MR_TARGET = 'staging'
  CONFIG_TARGET = 'master'
  BRANCH = 'autodev/91-target-branch'

  # One file, `app.rb`, twenty lines, and three branches cut from the same commit
  # that each edit a different line of it — far enough apart that no pair of them
  # conflicts, so what a rebase produces is a fact about its base and not about
  # git's conflict resolution:
  #
  #   init ──┬── staging: line 20 → "staging-line"   (the MR's target)
  #          ├── master:  line  1 → "master-line"    (the config's target)
  #          └── BRANCH:  line 10 → "autodev-line"   (the work)
  #
  # `staging` is also the repository's default branch, as it was on PowerPanne.
  FILE = 'app.rb'
  LINE_COUNT = 20

  def build_bare_origin(tmpdir)
    seed = File.join(tmpdir, 'seed')
    build_seed(seed)
    bare = File.join(tmpdir, 'origin.git')
    system('git', 'clone', '--bare', seed, bare, out: File::NULL, err: File::NULL)
    bare
  end

  def build_seed(seed)
    git_init_on(seed, MR_TARGET)
    write_and_commit(seed, FILE, numbered_lines, 'init')
    write_and_commit(seed, FILE, numbered_lines(20 => 'staging-line'), 'staging moves ahead')
    checkout_new(seed, CONFIG_TARGET, 'HEAD~1')
    write_and_commit(seed, FILE, numbered_lines(1 => 'master-line'), 'master moves ahead')
    checkout_new(seed, BRANCH, "#{MR_TARGET}~1")
    write_and_commit(seed, FILE, numbered_lines(10 => 'autodev-line'), 'autodev work')
    # Leaves the bare clone's HEAD on the MR's target, which is the repository's
    # default branch here as it is on PowerPanne.
    system('git', 'checkout', MR_TARGET, chdir: seed, out: File::NULL, err: File::NULL)
  end

  def numbered_lines(edits = {})
    (1..LINE_COUNT).map { |n| "#{edits[n] || "line#{n}"}\n" }.join
  end

  def git_init_on(dir, branch)
    FileUtils.mkdir_p(dir)
    system('git', 'init', chdir: dir, out: File::NULL, err: File::NULL)
    system('git', 'config', 'user.email', 't@t.com', chdir: dir, out: File::NULL, err: File::NULL)
    system('git', 'config', 'user.name', 'Test', chdir: dir, out: File::NULL, err: File::NULL)
    system('git', 'checkout', '-b', branch, chdir: dir, out: File::NULL, err: File::NULL)
  end

  def checkout_new(dir, branch, from)
    system('git', 'checkout', '-b', branch, from, chdir: dir, out: File::NULL, err: File::NULL)
  end

  def write_and_commit(dir, path, content, message)
    File.write(File.join(dir, path), content)
    system('git', 'add', path, chdir: dir, out: File::NULL, err: File::NULL)
    system('git', 'commit', '-m', message, chdir: dir, out: File::NULL, err: File::NULL)
  end

  def subjects(work_dir)
    `git -C #{work_dir} log --format=%s`.split("\n")
  end
end

# --- 1. the defect, replayed on the MR discussion fix ----------------------

# `MrFixer` is the caller with the shortest path to the damage: it clones the MR
# branch, rebases it, and pushes — and a rebase always needs force, so the push
# it ends on rewrites the branch GitLab is diffing.
class MrFixRebasesOnTheMrsTargetTest < Minitest::Test
  include RebaseBaseFixtures
  include DatabaseTestHelper

  class StubClient
    attr_reader :mr_reads

    def initialize(target:, mr_error: nil)
      @target = target
      @mr_error = mr_error
      @mr_reads = 0
    end

    def merge_request(_path, iid)
      @mr_reads += 1
      raise @mr_error if @mr_error

      RebaseBaseFixtures::FakeMr.new(iid, 'opened', @target, nil)
    end

    def merge_request_discussions(_path, _iid, **_opts)
      RebaseBaseFixtures::FakePaginated.new([RebaseBaseFixtures::FakeDiscussion.new(
        'open-thread',
        [RebaseBaseFixtures::FakeNote.new(true, false, 'please fix this', nil, '2026-08-30T10:00:00Z',
                                          RebaseBaseFixtures::FakePosition.new('app.rb', 10, nil))]
      )])
    end

    def issue(_path, iid)
      RebaseBaseFixtures::FakeIssuePayload.new(iid, 'La cible de la MR', 'body', 'opened')
    end

    def issue_notes(_path, _iid, **_opts) = RebaseBaseFixtures::FakePaginated.new([])
    def issue_links(_path, _iid) = []
    def resolve_merge_request_discussion(*_args, **_opts) = nil
  end

  def setup
    setup_database
    @tmpdir = Dir.mktmpdir('rebase_base_test')
    @bare = build_bare_origin(@tmpdir)
    @pushed = []
    @prompts = []
  end

  def teardown = FileUtils.rm_rf(@tmpdir)

  # A real fix round with the git half real and the Claude half stubbed.
  def run_round(target: MR_TARGET, mr_error: nil, config: { 'target_branch' => CONFIG_TARGET })
    issue = create_issue(mr_iid: 42, mr_url: 'http://gitlab/mr/42', branch_name: BRANCH, review_count: 1)
    advance_to(issue, 'checking_pipeline')
    issue._review_count_over_zero = true
    issue._unresolved_discussions_empty = false
    issue.pipeline_green!
    client = StubClient.new(target: target, mr_error: mr_error)
    SkillsInjector.stub(:inject, { all_skills: [] }) { fixer(client, config).fix(issue) }
    [issue.reload, client]
  end

  def fixer(client, config)
    MrFixer.allocate.tap do |fix|
      { client: client, project_path: 'group/project', project_config: config,
        config: {}, logger: StubLogger.new, token: 'tok', gitlab_url: 'https://gitlab.example' }
        .each { |name, value| fix.instance_variable_set(:"@#{name}", value) }
      stub_git(fix)
      stub_claude(fix)
      %i[log log_error].each { |noop| fix.define_singleton_method(noop) { |*| nil } }
      fix.define_singleton_method(:log_activity) { |*, **| nil }
      fix.define_singleton_method(:notify_localized) { |*, **| nil }
    end
  end

  # The clone is the only git command replaced: `clone_and_checkout` builds an
  # https URL from @gitlab_url, and the origin here is a path on disk. Everything
  # the ticket is about — the fetch, the `git log` probe, the rebase, the diff —
  # runs for real.
  def stub_git(fix)
    bare = @bare
    fix.define_singleton_method(:clone_and_checkout) do |work_dir, branch|
      FileUtils.rm_rf(work_dir)
      system('git', 'clone', '--depth', '1', '--branch', branch, bare, work_dir,
             out: File::NULL, err: File::NULL)
    end
    stub_push(fix)
  end

  def stub_push(fix)
    pushed = @pushed
    fix.define_singleton_method(:push_with_lease_fallback) do |work_dir, branch, **_opts|
      pushed << { branch: branch, subjects: `git -C #{work_dir} log --format=%s`.split("\n") }
    end
  end

  def stub_claude(fix)
    prompts = @prompts
    fix.define_singleton_method(:danger_claude_prompt) { |_dir, prompt, **_o| prompts << prompt }
    fix.define_singleton_method(:danger_claude_commit) { |*, **| nil }
    fix.define_singleton_method(:detect_agent) { |*| nil }
  end

  # The defect, end to end: the branch must be rebased onto `staging`, which is
  # what the merge request targets — not onto `master`, which is only where the
  # project's *next* merge request would go.
  def test_the_rebase_lands_on_the_target_the_merge_request_carries
    run_round

    refute_empty @pushed, 'the rebase onto the MR target had commits to take and was not performed'
    assert_includes @pushed.first[:subjects], 'staging moves ahead'
    refute_includes @pushed.first[:subjects], 'master moves ahead',
                    'the branch was rebased onto the config target, which the MR does not diff against'
  end

  # Requirement 3 of the ticket: the hunk quoted to danger-claude is computed
  # against the same base as the rebase. `build_fix_env` used to answer
  # `default_branch(work_dir)`, ignoring even the config — so on a
  # `--branch <x> --depth 1` clone with no `origin/HEAD` it asked git for
  # `origin/main..HEAD` and quoted nothing at all.
  def test_the_quoted_hunk_is_computed_against_the_same_base # rubocop:disable Minitest/MultipleAssertions
    run_round

    prompt = @prompts.first

    refute_nil prompt, 'no fix prompt was built'
    assert_includes prompt, '#### Diff', 'the thread quoted no diff hunk at all'
    assert_includes prompt, 'autodev-line'
    refute_includes prompt, 'staging-line',
                    'the hunk was computed against a base other than the one the branch was rebased on'
    refute_includes prompt, 'master-line',
                    'the hunk was computed against the config target, which the MR does not diff against'
  end

  # Requirement 4: the MR's target comes from a GitLab read, and a read that
  # failed is not a value. It must not fall back on the config — that is the
  # silent fallback which hid the defect — and it must not be charged to the
  # correction either (Autodev #67): the row stays in `fixing_discussions` for
  # `dispatch_discussions` to re-enqueue.
  def test_an_unreadable_merge_request_rebases_and_pushes_nothing # rubocop:disable Minitest/MultipleAssertions
    issue, = run_round(mr_error: api_error)

    assert_empty @pushed, 'nothing may be force-pushed behind a read that did not answer'
    assert_equal 'fixing_discussions', issue.status
    refute_equal 'error', issue.status
    assert_equal 0, issue.fix_round, 'no round may be counted for a poll that concluded nothing'
    assert_nil issue.error_message
  end

  # Requirement 5: the MR targets a branch that is no longer on the remote.
  # Autodev #89 settled the neighbouring case for the review skill — abort, the
  # line waits, never an invented verdict — and the same answer applies: there is
  # no base, so nothing is measured, rebased or pushed.
  def test_a_target_branch_that_is_gone_aborts_instead_of_rebasing_on_the_config
    issue, = run_round(target: 'staging-deleted-last-week')

    assert_empty @pushed, 'a base that does not exist may not be replaced by the config'
    assert_equal 'fixing_discussions', issue.status
    assert_equal 0, issue.fix_round
  end

  # Control: the config is still the answer where no merge request exists. Here
  # one does, so this is the *other* half — a project whose config agrees with
  # its MRs is unaffected, which is the fleet on 01/09.
  def test_a_config_that_agrees_with_the_merge_request_behaves_as_before
    run_round(target: CONFIG_TARGET, config: { 'target_branch' => CONFIG_TARGET })

    refute_empty @pushed
    assert_includes @pushed.first[:subjects], 'master moves ahead'
  end
end

# --- 2. the pipeline fix, same seam ---------------------------------------

# `PipelineMonitor::FailureHandler#prepare_work_dir` rebases too, and its
# boundary is `check` rather than `fix`. The property to pin is the one the
# stagnation counter depends on: a poll that could not read the MR's target
# concluded nothing, so it must not spend one of `stagnation_threshold`.
class PipelineFixRebasesOnTheMrsTargetTest < Minitest::Test
  include RebaseBaseFixtures
  include DatabaseTestHelper

  CODE_JOBS = [{ 'name' => 'rspec', 'stage' => 'test', 'status' => 'failed',
                 'allow_failure' => false, 'failure_reason' => 'script_failure' }].freeze

  FakePipeline = Struct.new(:id, :status)

  class StubClient
    attr_reader :mr_reads

    def initialize(target:, mr_error: nil)
      @target = target
      @mr_error = mr_error
      @mr_reads = 0
    end

    # The head-pipeline read of `poll_open_mr` and the target read are the same
    # endpoint; only the second may be refused, so the poll gets as far as the
    # fix before the target question is asked.
    def merge_request(_path, iid)
      @mr_reads += 1
      raise @mr_error if @mr_error && @mr_reads > 1

      RebaseBaseFixtures::FakeMr.new(iid, 'opened', @target,
                                     PipelineFixRebasesOnTheMrsTargetTest::FakePipeline.new(9, 'failed'))
    end

    def pipeline_jobs(_path, _pid, **_opts) = CODE_JOBS

    def issue(_path, iid)
      RebaseBaseFixtures::FakeIssuePayload.new(iid, 'La cible de la MR', 'body', 'opened')
    end

    def issue_notes(_path, _iid, **_opts) = RebaseBaseFixtures::FakePaginated.new([])
    def issue_links(_path, _iid) = []
    def merge_request_discussions(_path, _iid, **_opts) = RebaseBaseFixtures::FakePaginated.new([])
  end

  def setup
    setup_database
    @tmpdir = Dir.mktmpdir('rebase_base_pipeline_test')
    @bare = build_bare_origin(@tmpdir)
    @pushed = []
  end

  def teardown = FileUtils.rm_rf(@tmpdir)

  def poll(target: MR_TARGET, mr_error: nil)
    issue = create_issue(mr_iid: 42, mr_url: 'http://gitlab/mr/42', branch_name: BRANCH,
                         issue_author_id: 7, review_count: 1)
    advance_to(issue, 'checking_pipeline')
    monitor(StubClient.new(target: target, mr_error: mr_error)).check(issue)
    issue.reload
  end

  def monitor(client)
    PipelineMonitor.allocate.tap do |mon|
      { client: client, project_path: 'group/project',
        project_config: { 'target_branch' => CONFIG_TARGET }, config: {},
        logger: StubLogger.new, token: 'tok', gitlab_url: 'https://gitlab.example' }
        .each { |name, value| mon.instance_variable_set(:"@#{name}", value) }
      stub_fix_path(mon)
      stub_git(mon)
      stub_sinks(mon)
    end
  end

  def stub_sinks(mon)
    %i[log log_error].each { |noop| mon.define_singleton_method(noop) { |*| nil } }
    mon.define_singleton_method(:log_activity) { |*, **| nil }
    mon.define_singleton_method(:notify_localized) { |*, **| nil }
    mon.define_singleton_method(:apply_label_done) { |*| nil }
    mon.define_singleton_method(:reassign_to_author) { |*| nil }
  end

  def stub_fix_path(mon)
    mon.define_singleton_method(:claude_available?) { true }
    mon.define_singleton_method(:pre_triage) { |_jobs| { verdict: :code, explanation: 'rspec is red' } }
    mon.define_singleton_method(:write_and_categorize_jobs) do |*|
      [{ name: 'rspec', category: :test, log_path: '/tmp/rspec.log' }]
    end
    mon.define_singleton_method(:fix_each_job) { |*| nil }
    mon.define_singleton_method(:push_fixes) { |*| nil }
  end

  def stub_git(mon)
    bare = @bare
    pushed = @pushed
    mon.define_singleton_method(:clone_and_checkout) do |work_dir, branch|
      FileUtils.rm_rf(work_dir)
      system('git', 'clone', '--depth', '1', '--branch', branch, bare, work_dir,
             out: File::NULL, err: File::NULL)
    end
    mon.define_singleton_method(:push_with_lease_fallback) do |work_dir, branch, **_opts|
      pushed << { branch: branch, subjects: `git -C #{work_dir} log --format=%s`.split("\n") }
    end
  end

  def test_the_pipeline_fix_rebases_on_the_target_the_merge_request_carries
    SkillsInjector.stub(:inject, { all_skills: [] }) { poll }

    refute_empty @pushed
    assert_includes @pushed.first[:subjects], 'staging moves ahead'
    refute_includes @pushed.first[:subjects], 'master moves ahead'
  end

  # The counter is the thing an outage must not spend (Autodev #71): the
  # signature is written after `clone_and_fix` returns, so an abort inside it
  # leaves the column untouched and the row on the pipeline watch.
  def test_an_unreadable_target_spends_no_stagnation_budget # rubocop:disable Minitest/MultipleAssertions
    issue = SkillsInjector.stub(:inject, { all_skills: [] }) { poll(mr_error: api_error) }

    assert_empty @pushed
    assert_equal 'checking_pipeline', issue.status
    assert_nil issue.stagnation_signatures
    refute_equal 'error', issue.status
  end
end

# --- 3. the controls: the initial implementation, where no MR exists -------

# The config is not "the wrong answer" — it is the only one available before the
# merge request exists, and it is the right one, because the MR will be created
# with exactly that value. These two pin that the nominal path does not move.
class NoMergeRequestStillUsesTheConfigTest < Minitest::Test
  include RebaseBaseFixtures

  # Host class exposing the private helpers with the shell + repo plumbing they
  # expect, and nothing else stubbed: no client at all, because none is needed
  # when there is no merge request to read.
  class Harness
    include ShellHelpers
    include RepoOperations
    include RepoRebaser

    attr_reader :pushed

    def initialize(project_config:)
      @project_config = project_config
      @project_path = 'group/project'
      @client = nil
      @pushed = []
    end

    def push_with_lease_fallback(_work_dir, branch, upstream: false)
      @pushed << { branch: branch, upstream: upstream }
    end

    def danger_claude_prompt(*_args, **_opts) = nil
    def log(_msg) = nil
    def log_error(_msg) = nil
  end

  def setup
    @tmpdir = Dir.mktmpdir('rebase_base_config_test')
    @bare = build_bare_origin(@tmpdir)
    @work_dir = File.join(@tmpdir, 'clone')
  end

  def teardown = FileUtils.rm_rf(@tmpdir)

  # The clone the initial implementation makes: `--branch <config target>`, then
  # the previously-pushed autodev branch fetched and checked out on top (the
  # `reuse` path of `GitOperations#resolve_branch`).
  def clone_config_target_then_checkout(branch)
    system('git', 'clone', '--depth', '1', '--branch', CONFIG_TARGET, @bare, @work_dir,
           out: File::NULL, err: File::NULL)
    system('git', 'fetch', 'origin', "+refs/heads/#{branch}:refs/remotes/origin/#{branch}",
           chdir: @work_dir, out: File::NULL, err: File::NULL)
    system('git', 'checkout', '-b', branch, "origin/#{branch}", chdir: @work_dir,
                                                                out: File::NULL, err: File::NULL)
  end

  def test_a_branch_with_no_merge_request_rebases_on_the_configured_target
    harness = Harness.new(project_config: { 'target_branch' => CONFIG_TARGET })
    clone_config_target_then_checkout(BRANCH)

    base = harness.send(:target_branch_for, @work_dir, nil)
    verdict = harness.send(:rebase_branch_on_target, @work_dir, BRANCH, base: base)

    assert_equal CONFIG_TARGET, base
    assert_equal :rebased, verdict
    assert_includes subjects(@work_dir), 'master moves ahead'
  end

  # And with no `target_branch` declared, the repository's own default branch —
  # the pre-existing fallback, unchanged.
  def test_an_undeclared_target_still_falls_back_on_the_repository_default
    harness = Harness.new(project_config: {})
    system('git', 'clone', '--depth', '1', @bare, @work_dir, out: File::NULL, err: File::NULL)

    assert_equal MR_TARGET, harness.send(:target_branch_for, @work_dir, nil)
  end
end

# --- 4. the controls: verify_changes and the clone preparation -------------

class ImplementationSideStillWorksTest < Minitest::Test
  include RebaseBaseFixtures

  def setup
    @tmpdir = Dir.mktmpdir('rebase_base_impl_test')
    @bare = build_bare_origin(@tmpdir)
    @work_dir = File.join(@tmpdir, 'clone')
    @processor = IssueProcessor.allocate
    { project_path: 'group/project', project_config: { 'target_branch' => CONFIG_TARGET },
      config: {}, logger: StubLogger.new, client: nil }
      .each { |name, value| @processor.instance_variable_set(:"@#{name}", value) }
    %i[log log_error].each { |noop| @processor.define_singleton_method(noop) { |*| nil } }
  end

  def teardown = FileUtils.rm_rf(@tmpdir)

  def test_verify_changes_accepts_a_branch_that_moved_off_the_configured_target
    system('git', 'clone', '--depth', '1', '--branch', CONFIG_TARGET, @bare, @work_dir,
           out: File::NULL, err: File::NULL)
    system('git', 'fetch', 'origin', "+refs/heads/#{BRANCH}:refs/remotes/origin/#{BRANCH}",
           chdir: @work_dir, out: File::NULL, err: File::NULL)
    system('git', 'checkout', '-b', BRANCH, "origin/#{BRANCH}", chdir: @work_dir,
                                                                out: File::NULL, err: File::NULL)

    @processor.send(:verify_changes, @work_dir, BRANCH, nil) # nothing raised
  end

  def test_verify_changes_still_refuses_a_branch_with_no_commit_of_its_own
    system('git', 'clone', '--depth', '1', '--branch', CONFIG_TARGET, @bare, @work_dir,
           out: File::NULL, err: File::NULL)

    assert_raises(ImplementationError) do
      @processor.send(:verify_changes, @work_dir, CONFIG_TARGET, nil)
    end
  end

  # The clone's `--branch` is the config's and only the config's: it happens
  # before any merge request is looked at, and its job is to give the fresh
  # implementation the branch new work is cut from.
  def test_the_clone_command_still_takes_its_branch_from_the_config
    cmd = @processor.send(:build_clone_cmd, 'https://example/repo.git', '/tmp/x')

    assert_includes cmd.each_cons(2).to_a, ['--branch', CONFIG_TARGET]
  end

  def test_the_clone_command_names_no_branch_when_the_config_declares_none
    @processor.instance_variable_set(:@project_config, {})

    refute_includes @processor.send(:build_clone_cmd, 'https://example/repo.git', '/tmp/x'), '--branch'
  end
end

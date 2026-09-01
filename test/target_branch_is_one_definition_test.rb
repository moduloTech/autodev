# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/target_branch'
require 'autodev/danger_claude_runner'
require 'autodev/issue_processor'
require 'autodev/mr_fixer'
require 'autodev/pipeline_monitor'

# Autodev #91 — "which branch is this work targeting" has one definition, and six
# readers.
#
# It had three answers. `@project_config['target_branch'] || default_branch` was
# written out by hand in the rebaser, in `create_merge_request`, in
# `verify_changes` and in the clone command; `build_fix_env` answered
# `default_branch(work_dir)` alone, ignoring even the configuration, and that is
# what `DiscussionFormatter` computes the quoted hunk from; and the target the
# merge request itself carries was read by nobody at all — `PipelineMonitor`
# holds the `mr` object and never passed it on.
#
# The rule this ticket settled: **a new merge request takes the configuration, an
# existing one takes the target it carries.** The configuration is not the wrong
# answer, it is the answer to the other question — where the project's *next*
# merge request goes — and `create_merge_request` writes it into the MR, so the
# two are equal at birth and diverge only once the configuration moves under open
# merge requests.
#
# Like `test/mr_state_is_one_definition_test.rb` before it, this file has two
# halves. The readers all consult the one definition — proved by changing that
# definition and watching every one of them change with it — and each of them
# still takes its own decision about what to do with the answer.

# A branch name nobody can arrive at by accident: it is neither the project's
# configuration nor any repository's default. A reader carrying its own copy of
# the question will not produce it.
SENTINEL_BASE = 'release/2027-q1'

module TargetBranchFixtures
  FakeMr = Struct.new(:iid, :state, :target_branch)

  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  def api_error
    Gitlab::Error::ResponseError.new(
      FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/x'))
    )
  end

  class StubClient
    def initialize(target: 'staging', error: nil)
      @target = target
      @error = error
    end

    def merge_request(_path, iid)
      raise @error if @error

      TargetBranchFixtures::FakeMr.new(iid, 'opened', @target)
    end
  end

  # Answers the sentinel to whichever half of the question is asked, so a reader
  # that still writes its own answer is visible as the absence of the sentinel.
  def with_one_definition_answering(&)
    TargetBranch.stub(:of_merge_request, ->(*_args) { SENTINEL_BASE }) do
      TargetBranch.stub(:for_new_merge_request, ->(*_args) { SENTINEL_BASE }) do
        TargetBranch.stub(:declared, ->(*_args) { SENTINEL_BASE }, &)
      end
    end
  end
end

# --- 0. the home of the answer --------------------------------------------

class TargetBranchDefinitionTest < Minitest::Test
  include TargetBranchFixtures

  def test_the_project_declares_its_target_or_declares_nothing
    assert_equal 'staging', TargetBranch.declared({ 'target_branch' => 'staging' })
    assert_nil TargetBranch.declared({})
    assert_nil TargetBranch.declared(nil)
  end

  # A blank string is not a declaration. The dashboard's edit form posts one for
  # every field the operator left empty.
  def test_a_blank_declaration_is_no_declaration
    assert_nil TargetBranch.declared({ 'target_branch' => '  ' })
  end

  # Question 1: no merge request exists yet, so the project answers.
  def test_a_new_merge_request_goes_where_the_project_says
    assert_equal 'develop', TargetBranch.for_new_merge_request({ 'target_branch' => 'develop' }, 'master')
    assert_equal 'master', TargetBranch.for_new_merge_request({}, 'master')
  end

  # Question 2: the merge request exists, so it answers — even when the project's
  # configuration has since moved somewhere else entirely. This is PowerPanne on
  # 25/08/2026, and the whole of the ticket.
  def test_an_existing_merge_request_goes_where_it_says_it_goes
    base = TargetBranch.of_merge_request(StubClient.new(target: 'staging'), 'group/project', 10_837)

    assert_equal 'staging', base
  end

  def test_the_two_questions_are_dispatched_on_whether_a_merge_request_exists
    args = { client: StubClient.new(target: 'staging'), project_path: 'group/project',
             project_config: { 'target_branch' => 'master' } }

    assert_equal 'staging', TargetBranch.resolve(42, **args) { 'repository-default' }
    assert_equal 'master', TargetBranch.resolve(nil, **args) { 'repository-default' }
  end

  def test_the_repository_default_is_not_resolved_when_a_merge_request_answers
    called = false
    TargetBranch.resolve(42, client: StubClient.new, project_path: 'g/p', project_config: {}) do
      called = true
      'repository-default'
    end

    refute called, 'the local git probe must not run when GitLab already holds the answer'
  end

  # Autodev #67: the target comes from a GitLab read, so a read that failed is not
  # a value. Falling back on the configuration here is exactly the silent
  # substitution that let the defect run for a week without a trace.
  def test_a_read_that_failed_does_not_fall_back_on_the_configuration
    client = StubClient.new(error: api_error)

    error = assert_raises(ApiUnavailableError) do
      TargetBranch.resolve(42, client: client, project_path: 'g/p',
                               project_config: { 'target_branch' => 'master' }) { 'master' }
    end

    assert_equal :merge_request_target, error.what
  end

  # A merge request GitLab describes without a target is not a merge request whose
  # target is the configuration's.
  def test_a_merge_request_naming_no_target_aborts
    assert_raises(MissingTargetBranchError) do
      TargetBranch.of_merge_request(StubClient.new(target: ''), 'g/p', 42)
    end
  end

  # `GitlabHelpers.field` is the shape reader (Autodev #62's sibling): the gitlab
  # gem hands back objects, tests and some paths hand back hashes.
  def test_the_answer_is_read_off_whatever_shape_gitlab_returned
    hash_client = Class.new do
      def merge_request(_path, _iid) = { 'target_branch' => 'staging' }
    end.new

    assert_equal 'staging', TargetBranch.of_merge_request(hash_client, 'g/p', 42)
  end
end

# --- 1. the source guard: no reader writes the answer out again ------------

# Derived from the tree rather than from a list kept by hand: the two expressions
# that used to be copied around are grepped for, and the only file allowed to
# contain either is `lib/autodev/target_branch.rb`, which defines the answer.
#
# The perimeter is `lib/`, which is where every write action lives — the rebase,
# the force-push, the merge-request creation, the diff a review thread is quoted
# with. That is asserted below rather than claimed, by checking that nothing
# under `app/` performs any of them.
#
# One hand-written copy is knowingly left outside that perimeter and is named
# here rather than hidden: `Autodev::ReviewSkillProbe#ref_for`
# (`app/services/autodev/review_skill_probe.rb`) still spells
# `project['target_branch']` … `client.project(...).default_branch`. It is on the
# *no merge request* side of the rule — it sweeps the configured fleet, project by
# project, with no merge request in hand — so the configuration is its correct
# answer and it decides nothing about a rebase or a push. It also belongs to
# Autodev #89, which is rewriting that file in another branch; folding it in is a
# one-line follow-up, not a silent divergence.
class TargetBranchHasNoSecondCopyTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  # The configuration read, in its indexing form. `%w[target_branch …]` field
  # lists (`Config::DB_BACKED_PROJECT_FIELDS`, `Project::SCALAR_CONFIG_KEYS`) name
  # the setting, they do not answer the question, and are deliberately not matched.
  CONFIG_READ = /\[['"]target_branch['"]\]/
  # The repository fallback, in its calling form (the comments that merely mention
  # the method do not have the parenthesis).
  REPOSITORY_FALLBACK = /\bdefault_branch\(/

  # The three write actions the rule governs.
  WRITE_ACTIONS = /\b(rebase_branch_on_target|verify_changes|create_merge_request)\(/

  def ruby_files(dir)
    Dir[File.join(ROOT, dir, '**', '*.rb')]
  end

  # Code only. Every file this ticket touched documents the expression it took
  # out — that is how the next reader learns why asking is not optional — and a
  # guard that counted those sentences would make the documentation the offence.
  def code_of(path)
    File.readlines(path).grep_v(/^\s*#/).join
  end

  def files_matching(dir, pattern)
    ruby_files(dir).select { |path| code_of(path).match?(pattern) }
                   .map { |path| path.delete_prefix("#{ROOT}/") }
  end

  def test_the_configuration_is_read_in_exactly_one_place
    assert_equal ['lib/autodev/target_branch.rb'], files_matching('lib', CONFIG_READ), <<~MSG
      A second answer to "which branch is this work targeting" is written out here.

      Ask `TargetBranch` instead — through `target_branch_for(work_dir, mr_iid)`
      when a clone is in hand. The configuration answers only the case where no
      merge request exists yet; a hand-written copy cannot know which case it is
      in, which is how a branch came to be rebased and force-pushed onto a base
      its merge request was not being diffed against (Autodev #91).
    MSG
  end

  # The same file, which is the point: the repository fallback is what an
  # undeclared `target_branch` *means*, so it is a private step of the answer and
  # not an answer. Read on its own it is the third of the three (it was
  # `build_fix_env`'s, and it ignored even the configuration).
  def test_the_repository_fallback_is_reached_from_exactly_one_place
    assert_equal ['lib/autodev/target_branch.rb'], files_matching('lib', REPOSITORY_FALLBACK), <<~MSG
      `default_branch` is half of the answer, not an answer. It lives next to
      `target_branch_for`, which is the only thing entitled to call it.
    MSG
  end

  # What makes `lib/` the right perimeter, re-derived on every run.
  def test_no_write_action_lives_outside_that_perimeter
    assert_empty files_matching('app', WRITE_ACTIONS),
                 'a rebase, a verification or a merge-request creation moved out of lib/; widen the scan'
  end
end

# --- 2. the six readers all consult it, and each keeps its own decision -----

# The proof shape Autodev #72 used for `MrState`: change the one definition, and
# every reader changes with it. A reader still carrying its own copy answers its
# own branch, not the sentinel.
class EveryReaderAsksTheOneDefinitionTest < Minitest::Test
  include TargetBranchFixtures

  CONFIG = { 'target_branch' => 'master' }.freeze

  def build(klass, extra = {})
    klass.allocate.tap do |obj|
      { client: StubClient.new, project_path: 'group/project', project_config: CONFIG,
        config: {}, logger: StubLogger.new, token: 'tok', gitlab_url: 'https://gitlab.example' }
        .merge(extra).each { |name, value| obj.instance_variable_set(:"@#{name}", value) }
      %i[log log_error].each { |noop| obj.define_singleton_method(noop) { |*| nil } }
      obj.define_singleton_method(:log_activity) { |*, **| nil }
      obj.define_singleton_method(:default_branch) { |*| 'repository-default' }
    end
  end

  # 1 — the MR discussion fix: the base it rebases on, and the base the quoted
  # hunk is computed against, are the same value and both come from here.
  def stub_fix_cycle(fixer, seen)
    fixer.define_singleton_method(:clone_and_checkout) { |*| nil }
    fixer.define_singleton_method(:rebase_branch_on_target) { |_d, _b, base:| seen[:rebase] = base }
    fixer.define_singleton_method(:prepare_fix_environment) { |_d, _i, _m, base| seen[:env] = base }
    fixer.define_singleton_method(:fix_each_discussion) { |*| [] }
    fixer.define_singleton_method(:new_commits?) { |*| false }
    fixer.define_singleton_method(:finalize_no_commits) { |*| nil }
  end

  def test_the_discussion_fix_asks_for_both_the_rebase_and_the_hunk
    fixer = build(MrFixer)
    seen = {}
    stub_fix_cycle(fixer, seen)

    with_one_definition_answering do
      fixer.send(:run_fix_cycle, Struct.new(:branch_name, :mr_iid, :issue_iid).new('autodev/1', 42, 7),
                 [], '/tmp/does-not-matter')
    end

    assert_equal({ rebase: SENTINEL_BASE, env: SENTINEL_BASE }, seen)
  end

  # 2 — the pipeline fix.
  def test_the_pipeline_fix_asks_before_it_rebases
    monitor = build(PipelineMonitor)
    seen = nil
    monitor.define_singleton_method(:clone_and_checkout) { |*| nil }
    monitor.define_singleton_method(:rebase_branch_on_target) { |_d, _b, base:| seen = base }
    issue = Struct.new(:branch_name, :mr_iid).new('autodev/1', 42)

    SkillsInjector.stub(:inject, { all_skills: [] }) do
      with_one_definition_answering { monitor.send(:prepare_work_dir, '/tmp/does-not-matter', issue) }
    end

    assert_equal SENTINEL_BASE, seen
  end

  # 3 — the re-implementation, the one reader that can be in either case: the
  # branch is reused, and a merge request may or may not already carry it.
  def test_the_reimplementation_asks_with_the_merge_request_it_has
    processor = build(IssueProcessor)
    seen = nil
    processor.define_singleton_method(:fetch_and_checkout) { |*| nil }
    processor.define_singleton_method(:rebase_branch_on_target) { |_d, _b, base:| seen = base }
    issue = Struct.new(:mr_iid, :issue_title).new(42, 'T')

    with_one_definition_answering do
      processor.send(:resolve_branch, '/tmp/does-not-matter', 7, issue, 'autodev/1', true)
    end

    assert_equal SENTINEL_BASE, seen
  end

  # 4 — the verification that the implementation produced something.
  def test_the_change_verification_measures_against_the_same_base
    processor = build(IssueProcessor)
    seen = nil
    processor.define_singleton_method(:run_cmd_status) do |cmd, **_o|
      seen = cmd
      ['abc123 a commit', '', true]
    end

    with_one_definition_answering { processor.send(:verify_changes, '/tmp/x', 'autodev/1', 42) }

    assert_includes seen, "origin/#{SENTINEL_BASE}..autodev/1"
  end

  # 5 — the merge request creation, the config half of the rule: this is where the
  # value that every later reader gets back from GitLab is written.
  def test_the_merge_request_creation_asks_the_no_merge_request_half
    processor = build(IssueProcessor)
    seen = nil
    processor.define_singleton_method(:find_existing_mr) { |*| nil }
    processor.define_singleton_method(:run_cmd) { |*, **| 'feat: something' }
    processor.instance_variable_get(:@client).define_singleton_method(:create_merge_request) do |*_a, **kw|
      seen = kw[:target_branch]
      Struct.new(:iid, :web_url).new(1, 'url')
    end

    with_one_definition_answering { processor.send(:create_merge_request, '/tmp/x', 7, 'autodev/1', 'T') }

    assert_equal SENTINEL_BASE, seen
  end

  # 6 — the clone. It asks for the *declared* value and nothing else: `git clone`
  # with no `--branch` takes the remote's own HEAD, which is the same fallback by
  # another route and one round-trip cheaper.
  def test_the_clone_asks_for_the_declaration_only
    processor = build(IssueProcessor)

    cmd = with_one_definition_answering { processor.send(:build_clone_cmd, 'https://x/r.git', '/tmp/x') }

    assert_includes cmd.each_cons(2).to_a, ['--branch', SENTINEL_BASE]
  end

  # And the other half of Autodev #72's shape: sharing the answer is not sharing
  # the decision. Each reader still does its own thing with the same branch name —
  # the rebaser fetches and rewrites history with it, `verify_changes` raises on
  # it, the clone passes it to `--branch`, the formatter diffs one file against it.
  def test_the_readers_keep_their_own_decisions
    processor = build(IssueProcessor)
    processor.define_singleton_method(:run_cmd_status) { |*, **| ['', '', true] }

    assert_raises(ImplementationError) do
      with_one_definition_answering { processor.send(:verify_changes, '/tmp/x', 'autodev/1', 42) }
    end
  end
end

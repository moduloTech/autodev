# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'ruby_source_helper'
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
    def initialize(target: 'staging', error: nil, state: 'opened')
      @target = target
      @error = error
      @state = state
    end

    def merge_request(_path, iid)
      raise @error if @error

      TargetBranchFixtures::FakeMr.new(iid, @state, @target)
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

  # Question 2: the merge request exists **and still carries the work**, so it
  # answers — even when the project's configuration has since moved somewhere
  # else entirely. This is PowerPanne on 25/08/2026, and the whole of the ticket.
  #
  # "Still carries the work" and not "exists": a closed or merged merge request
  # exists and answers nothing, because there is no longer a branch of work whose
  # base is in question. The old name of this test said `existing`, which is the
  # weaker half of the rule and not the one the code implements.
  def test_a_merge_request_that_still_carries_the_work_goes_where_it_says_it_goes
    base = TargetBranch.of_merge_request(StubClient.new(target: 'staging'), 'group/project', 10_837)

    assert_equal 'staging', base
  end

  # The other half of the same sentence. A concluded merge request hands the
  # question back to the configuration (`resolve` falls through to question 1)
  # rather than naming a base to rebase onto.
  def test_a_merge_request_whose_work_is_over_answers_nothing
    MrState::CONCLUDED_STATES.each do |state|
      client = StubClient.new(target: 'staging', state: state)

      assert_nil TargetBranch.of_merge_request(client, 'group/project', 10_837),
                 "a #{state} merge request still answered question 2"
    end
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
  #
  # The hash below carries **no `state`**, and that is load-bearing rather than an
  # oversight: `of_merge_request` reads the state before the target, and this test
  # only gets as far as the target because `MrState.over?` is an **allow-list**, so
  # a state nobody described is not a concluded one. Written as a deny-list it
  # would answer `nil` here and the shape reading — the thing this test is for —
  # would go unchecked while the test still passed. The dependency is pinned by the
  # test below rather than left for a reader to rediscover.
  def test_the_answer_is_read_off_whatever_shape_gitlab_returned
    hash_client = Class.new do
      def merge_request(_path, _iid) = { 'target_branch' => 'staging' }
    end.new

    assert_equal 'staging', TargetBranch.of_merge_request(hash_client, 'g/p', 42)
  end

  # Autodev #72's rule, and what the test above rests on: the concluded states are
  # enumerated, so anything else — including nothing at all — is not concluded.
  def test_a_state_gitlab_did_not_describe_is_not_a_concluded_one
    refute MrState.over?(nil), 'the shape test above reaches the target only because this is false'
    refute MrState.over?('')
    refute MrState.over?('some_state_gitlab_adds_later')
  end
end

# --- 1. the source guard: no reader writes the answer out again ------------

# Derived from the tree rather than from a list kept by hand: the expressions that
# used to be copied around are grepped for, and the only file allowed to contain
# them is `lib/autodev/target_branch.rb`, which defines the answer. Everything
# else is an exception declared by name, with the reason, in `DECLARED`.
#
# The perimeter is `app/` **and** `lib/`. It used to be `lib/` alone, justified by
# a third test that asserted nothing under `app/` performed a rebase, a
# verification or a merge-request creation — by grepping for those three *method
# names*, so renaming one satisfied it. Scanning both directories removes the
# need for the justification, and the write-action test below now asks the
# question that is actually worth asking: where the write primitives live at all.
#
# ## Four ways to answer the question yourself, and why each is matched
#
# Three of these were reachable when this file was written and are what the review
# round of this lot closed:
#
#   * **the configuration, indexed**: `config['target_branch']`, and since this
#     round also `.fetch(…)`, `.dig(…)` and `config[SOME_CONSTANT]` where the
#     constant's value *is* `'target_branch'`. The alias set is read off the tree
#     (`KEY_ALIAS`), so a new alias is covered without touching this file. Field
#     lists (`Config::DB_BACKED_PROJECT_FIELDS`, `Project::SCALAR_CONFIG_KEYS`)
#     name the setting, they do not answer the question, and are not matched —
#     they spell the key as a bare `%w[]` element, never as an index.
#   * **the repository default**, in any spelling. The pattern is the bare
#     identifier now, not `default_branch(`: `default_branch work_dir` without
#     parentheses slipped past, and so did `client.project(path).default_branch`,
#     which is the same read one layer lower. Five lines in the whole of `app/`
#     and `lib/` mention it, so the broad form costs one declared exception and
#     closes three holes.
#   * **a private step of the module, called from outside**. This is the one an
#     adversarial reader used: `TargetBranch.repository_default(@client,
#     @project_path)` in `FixCycle` is, to the letter, the third answer Autodev #91
#     deleted — the repository's value with the configuration ignored, which is
#     what `build_fix_env` did — and it was matched by neither pattern above
#     because it spells neither the key nor the fallback's name. The set is
#     **derived from the module's own surface**: every `module_function` of
#     `TargetBranch` except the three a reader is entitled to call. A new public
#     half-answer is therefore in the perimeter the moment it is written.
#
# ## What this guard does not do
#
# It reads text. A reader that arrived at the answer through a variable, a
# `send`, or a method of its own named something else is invisible to it — which
# is why the second half of this file exists: `EveryReaderAsksTheOneDefinitionTest`
# changes the one definition and watches all six readers change with it. The two
# halves cover each other, and neither is enough.
class TargetBranchHasNoSecondCopyTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)
  DEFINITION = 'lib/autodev/target_branch.rb'

  # The three entry points a reader may call. Everything else `TargetBranch`
  # exposes is a private step of the answer — `for_new_merge_request` and
  # `repository_default` are the two halves of question 1, `for_fleet_scan` is
  # both of them at once, `named_target` is the shape reading — and calling one
  # from outside is answering the question yourself.
  ENTRY_POINTS = %i[declared resolve of_merge_request].freeze
  PRIVATE_STEPS = (TargetBranch.singleton_methods(false) - ENTRY_POINTS).sort.freeze

  # Constants whose value *is* the configuration key. `config[BRANCH_KEY]` reads
  # the configuration exactly as `config['target_branch']` does, and no literal
  # pattern can see it, so the aliases are read off the tree.
  KEY_ALIAS = /^\s*([A-Z][A-Z0-9_]*)\s*=\s*['"]target_branch['"]/

  # The write actions the rule governs, named by what they **do**. The three
  # method names this used to grep for could be renamed; `git push`, `git rebase`
  # and `--force-with-lease` cannot be, and `create_merge_request` is the gem's.
  WRITE_PRIMITIVES = /--force-with-lease|\bgit\W{1,4}(?:push|rebase)\b|\bcreate_merge_request\b/

  # Every exception, by file, with the reason it is not a second answer.
  #
  # `ReviewSkillProbe#ref_for` used to be declared here as a hand-written copy
  # knowingly left out of the perimeter. **That is no longer true**: the probe
  # delegates to `ReviewSkillSource`, which asks `TargetBranch`, and the CHANGELOG
  # of this lot says so. The sentence outlived the code by one integration, which
  # is the failure mode `ALLOWED_SWALLOWS` documents about itself in
  # `test/api_failure_is_not_a_verdict_test.rb` — "two plainly false declarations
  # survived a review" — reproduced in a file written the same week. Every entry
  # below was re-read against the code it names before this list was committed.
  DECLARED = {
    # The block `resolve` calls when no merge request answers, which is question
    # 1's other half and the same shape `Resolver#target_branch_for` uses with the
    # local git probe. It is here rather than there because the probe sweeps the
    # fleet with no clone to run `git symbolic-ref` in. Not a second answer: it is
    # *supplied to* `resolve`, and that is asserted below, not trusted.
    'lib/autodev/review_skill_source.rb' => :supplied_to_resolve,
    # Display. The project page renders the declared target, or a localized "not
    # set" when there is none. It decides nothing: no clone, no rebase, no
    # push, no diff. Deliberately **not** folded into `TargetBranch.declared`,
    # because `declared` treats a blank string as no declaration and this cell
    # currently renders the blank — the dashboard's own edit form posts one for
    # every field left empty, so changing what it shows is a product decision and
    # not a guard's to take in passing.
    'app/components/web/views/project_show.rb' => :display_only,
    # AutoSpec's brief refresher resolves the remote's HEAD with
    # `git ls-remote --symref` to pick which branch to clone for a *brief*. Same
    # fact, different question: it never sees a merge request or a project
    # configuration, and nothing is rebased, force-pushed or diffed against what
    # it returns — the clone it feeds is read-only.
    'app/services/autospec/project_briefer.rb' => :other_question,
    # `MISSING_BASE_KEY = 'target_branch'` is the key of the *stagnation
    # signature map* (`issues.stagnation_signatures`), not of the configuration.
    # It is matched only because the alias scan above is derived from the value,
    # and the value is a coincidence: the map is keyed by what is being counted.
    'lib/autodev/missing_base_bound.rb' => :not_the_configuration
  }.freeze

  def config_read
    aliases = key_aliases
    index = aliases.empty? ? nil : "|\\[\\s*(?:#{aliases.join('|')})\\s*\\]"
    /(?:\[|\bfetch\(|\bdig\()\s*['"]target_branch['"]#{index}/
  end

  # `CONST = 'target_branch'` anywhere under app/ or lib/.
  def key_aliases
    ruby_files.flat_map { |path| code_of(path).scan(KEY_ALIAS) }.flatten.uniq.sort
  end

  def repository_fallback = /\bdefault_branch\b/

  def short_circuit = /\bTargetBranch\.(?:#{PRIVATE_STEPS.join('|')})\b/

  def ruby_files
    Dir[File.join(ROOT, '{app,lib}', '**', '*.rb')]
  end

  # Code only. Every file this ticket touched documents the expression it took
  # out — that is how the next reader learns why asking is not optional — and a
  # guard that counted those sentences would make the documentation the offence.
  # Literals are kept: `config['target_branch']` *is* a literal, and it is the
  # offence.
  def code_of(path) = RubySource.uncommented_file(path)

  def offenders(pattern)
    ruby_files.select { |path| code_of(path).match?(pattern) }
              .map { |path| path.delete_prefix("#{ROOT}/") }
              .reject { |rel| rel == DEFINITION || DECLARED.key?(rel) }
  end

  def test_the_configuration_is_read_in_exactly_one_place
    assert_empty offenders(config_read), <<~MSG
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
    assert_empty offenders(repository_fallback), <<~MSG
      `default_branch` is half of the answer, not an answer. It lives next to
      `target_branch_for`, which is the only thing entitled to call it — and the
      match is the bare name, so `default_branch work_dir` without parentheses and
      `client.project(path).default_branch` are the same offence as a call.
    MSG
  end

  # The hole an adversarial reader walked through: a public method of the module
  # itself. Derived from the module's surface, so it cannot go stale.
  def test_no_private_step_of_the_answer_is_called_from_outside
    refute_empty PRIVATE_STEPS, 'the module exposes nothing but entry points; this guard now checks nothing'

    assert_empty offenders(short_circuit), <<~MSG
      A private step of `TargetBranch` is called from outside it: one of
      #{PRIVATE_STEPS.join(', ')}.

      `repository_default` on its own is the answer Autodev #91 deleted — the
      repository's value with the configuration ignored, which is what
      `build_fix_env` did and what `DiscussionFormatter` then quoted its hunks
      against. Ask `resolve` (or `target_branch_for`), which dispatches on whether
      a merge request exists, and let the fallback stay a step of it.
    MSG
  end

  # The one exception that is a *shape* rather than a purpose, checked instead of
  # believed: the private step has to be the block `resolve` calls, in the same
  # method, not a call standing on its own.
  def test_the_declared_fallback_is_supplied_to_resolve
    DECLARED.select { |_rel, why| why == :supplied_to_resolve }.each_key do |rel|
      assert_supplied_to_resolve(rel, code_of(File.join(ROOT, rel)).lines)
    end
  end

  # The call has to be inside a `TargetBranch.resolve` block, which for the shape
  # in question means on one of the three lines after it opens.
  def assert_supplied_to_resolve(rel, lines)
    calls = lines.each_index.select { |i| lines[i].match?(short_circuit) }

    refute_empty calls, "#{rel} is declared as supplying a fallback to `resolve` and calls no private step"
    calls.each do |i|
      opened = lines[[i - 3, 0].max...i].any? { |line| line.include?('TargetBranch.resolve') }

      assert opened, "#{rel}:#{i + 1} calls a private step of `TargetBranch` outside a `resolve` block"
    end
  end

  # What the perimeter above is worth knowing: the write actions the rule governs
  # all live under `lib/`. Not asserted by method name any more — renaming
  # `rebase_branch_on_target` satisfied that — but by the primitives themselves.
  def test_the_write_actions_live_under_lib
    outside = ruby_files.select { |path| path.start_with?(File.join(ROOT, 'app')) }
                        .select { |path| code_of(path).match?(WRITE_PRIMITIVES) }
                        .map { |path| path.delete_prefix("#{ROOT}/") }

    assert_empty outside, <<~MSG
      A push, a rebase or a merge-request creation lives under app/: #{outside.join(', ')}.

      The rule this file guards is about the base those actions use, so a new one
      outside lib/ is not a problem in itself — it is a place to re-read this
      file's patterns against, since they were written when every one of them was
      in lib/.
    MSG
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

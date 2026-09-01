# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require_relative 'ruby_source_helper'
require 'autodev/pipeline_monitor'

# "Which revision decides this project's review skill?" must have exactly one
# answer, and both askers must ask it (Autodev #89).
#
# The pendant of `test/skill_layouts_are_one_definition_test.rb`, which pins the
# *layouts*; this one pins the **ref**, which is the half that had diverged.
# `Autodev::ReviewSkillProbe` asked GitLab about the project's `target_branch`;
# `PipelineMonitor::SkillReviewer` cloned `issue.branch_name` and looked in the
# clone. Nothing said so, and the two disagreed in production: on 31/08/2026 the
# probe answered "2 declared, 2 present" — correctly — while 13 of the 23 live
# branches carried no review skill at all, and request powerpanne 15842 was given
# up on 28/08 under `review_skill_missing`.
#
# So the file asserts one property, from two directions:
#
#   * **derived**: no asker spells the ref, the layouts or the self-injected
#     derogation itself, and every asker *calls* the shared module. All three
#     come from `ReviewSkillSource`, so a change to any of them reaches every
#     reader or none. Who the askers are is derived too (`#askers` below): any
#     file under `app/` or `lib/` whose code mentions the module, so a third one
#     added tomorrow is in the perimeter without anybody remembering it;
#   * **behavioural**: on a repository state where the two questions have the
#     same answer, the two agree — same ref asked about, same layouts asked
#     about, same derogation — and a project the probe calls `present` cannot
#     produce `review_skill_missing`. The condition is not decoration: since the
#     round that applied Autodev #91 here, the review asks question 2 (the target
#     the merge request carries) and the probe asks question 1 (the target the
#     configuration declares). They are two questions, and
#     `test_the_two_askers_ask_two_different_questions_when_the_answers_differ`
#     pins the case where they diverge.
#
# Two limits, stated rather than left implicit:
#
#   * the derived half reads code only. What "code" means is `RubySource`'s, and
#     that is the second thing this round fixed: this file used to drop
#     whole-comment lines only, so a **trailing** comment counted as code, and
#     the "routes through the shared module" assertion was satisfied by
#     `# ReviewSkillSource` written after a hand-written copy. Demonstrated: the
#     probe carrying its own copy of `declared`, with the module named only in
#     tail comments and called nowhere, left green all seven tests this file then
#     had — the two derived assertions included;
#   * it proves that the askers share the ref, the layouts, the derogation and
#     the reading of `review_skill` itself. That last one was the gap this guard
#     declared until 01/09/2026: three spellings of "is a skill declared"
#     coexisted — raw in `SkillReviewer`, raw in `MrReviewTokenProbe`, `.presence`
#     in `Reviewer#launch_review` — and only the shared one trimmed, so a value
#     with surrounding whitespace took the skill path on one side and counted as
#     "no skill" on the other. All four now ask `ReviewSkillSource.declared`, and
#     `review_skill` is named in `OWNED_BY_THE_SHARED_MODULE` so a fourth
#     spelling fails here rather than being written down as a known limit.
#
# rubocop:disable Metrics/ClassLength -- the two directions only read together,
# and half of these lines are the pair of harnesses that make "the same GitLab
# state" mean the same thing on both sides. Splitting them would put the
# derivation and its counter-example in different files.
class ReviewAndProbeReadTheSameThingTest < Minitest::Test
  include DatabaseTestHelper

  SKILL = 'prepare-mr'
  SKILLS_DIR = '.claude/skills'
  CANONICAL = "#{SKILLS_DIR}/#{SKILL}/SKILL.md".freeze
  FLAT = "#{SKILLS_DIR}/#{SKILL}.md".freeze
  PROJECT_PATH = 'modulosource/ff/fast/core'

  ROOT = File.expand_path('..', __dir__)
  MODULE_SOURCE = File.join(ROOT, 'lib/autodev/review_skill_source.rb')
  PROBE_SOURCE = File.join(ROOT, 'app/services/autodev/review_skill_probe.rb')
  REVIEWER_SOURCE = File.join(ROOT, 'lib/autodev/pipeline_monitor/skill_reviewer.rb')
  # Spelling any of these in an asker is a second definition of the question.
  # `review_skill` is named by its *config read* and not by the bare word, because
  # the bare word is also a legitimate `ActivityEvent` kind (`ReviewSkillProbe::KIND`)
  # and the scan keeps string literals — it has to, since the config read is itself
  # a literal, so blanking them would blind the guard to the very thing it looks for.
  OWNED_BY_THE_SHARED_MODULE = ["['review_skill']", 'target_branch', 'default_branch',
                                'skill_paths', 'SKILL_NAMES', 'get_file'].freeze
  # Of those, the ones the shared module answers itself: whether a skill is
  # declared at all, the layouts it looks for, and the read it looks with. The
  # other two are the *ref*, and the module does not answer that either — it asks
  # `TargetBranch` (Autodev #91), which is why they are split rather than asserted
  # as one set.
  ANSWERED_BY_THE_SHARED_MODULE = ["['review_skill']", 'skill_paths', 'SKILL_NAMES', 'get_file'].freeze
  ASKS_TARGET_BRANCH = /\bTargetBranch\.\w+/
  # Not a name, a **call**. The name on its own is what a comment carries.
  ROUTED_THROUGH = /\bReviewSkillSource\.\w+/

  # The three repository states the two askers must agree on.
  STATES = {
    'the canonical layout on the target branch' => { CANONICAL => '# prepare-mr' },
    'the flat legacy layout on the target branch' => { FLAT => '# prepare-mr' },
    'neither layout anywhere' => {}
  }.freeze

  # Records the reads and answers them; deliberately smaller than the fakes in
  # the two behaviour files, since what is compared here is what was *asked*.
  class FakeGitlab
    Blob = Struct.new(:type, :path)
    Repo = Struct.new(:default_branch)
    Commit = Struct.new(:id)
    Mr = Struct.new(:iid, :state, :target_branch)

    attr_reader :calls, :default_branch
    # The target the merge request under review carries. The review asks question 2
    # of `TargetBranch` since the round that followed Autodev #91, so the fake has
    # to hold one; `review` below sets it to the configuration's own value, which
    # is the situation this file is about — the two askers must agree wherever the
    # two answers agree, and that is the whole fleet as measured.
    attr_accessor :mr_target

    # `only_on:` makes the repository state depend on the ref, which the
    # convergent cases do not need — every state below is the same on both
    # answers, because that is the situation this file is about. The divergent
    # case does need it: what it shows is one repository where the two questions
    # have different answers.
    def initialize(files: {}, default_branch: 'master', only_on: nil)
      @files = files
      @default_branch = default_branch
      @mr_target = default_branch
      @only_on = only_on
      @calls = []
    end

    def merge_request(_path, iid)
      @calls << [:merge_request, nil, nil]
      Mr.new(iid, 'opened', @mr_target)
    end

    def project(path)
      @calls << [:project, path, nil]
      Repo.new(@default_branch)
    end

    def get_file(_path, file, ref)
      @calls << [:get_file, file, ref]
      raise not_found unless carries?(file, ref)

      Struct.new(:file_path).new(file)
    end

    def commit(_path, ref)
      @calls << [:commit, nil, ref]
      Commit.new('deadbeef')
    end

    # `blobs_under` pairs `per_page: 100` with `.auto_paginate` like every other
    # list read here, so the answer is the gem's own response object and not an
    # Array.
    def tree(_path, options)
      @calls << [:tree, options[:path], options[:ref]]
      Gitlab::PaginatedResponse.new(@files.keys.select { |f| f.start_with?("#{options[:path]}/") }
                                         .map { |file| Blob.new('blob', file) })
    end

    def file_contents(_path, file, ref)
      @calls << [:file_contents, file, ref]
      @files.fetch(file)
    end

    private

    def carries?(file, ref) = @files.key?(file) && (@only_on.nil? || ref == @only_on)

    def not_found
      request = Struct.new(:base_uri, :path).new('https://gitlab.example', '/api/v4')
      Gitlab::Error::NotFound.new(Struct.new(:code, :parsed_response, :request).new(404, {}, request))
    end
  end

  class NullLogger
    %i[info warn error debug].each { |level| define_method(level) { |*, **| nil } }
  end

  Ticket = Struct.new(:issue_iid, :mr_iid, :branch_name, :locale)

  def setup = setup_database

  def project(target_branch: 'master', skill: SKILL)
    { 'path' => PROJECT_PATH, 'target_branch' => target_branch, 'review_skill' => skill }
  end

  # --- the two askers, each on its own client ------------------------------

  def probe(config, client)
    Autodev::ReviewSkillProbe.probe!(config: {}, projects: [config], client: client,
                                     logger: NullLogger.new).first
  end

  # Answers `:present` / `:missing` for the review step, in the probe's own
  # vocabulary, so the two are directly comparable.
  #
  # `mr_target` defaults to the configuration's own value, which is the case this
  # file is about and the whole of the fleet as measured. Pass `mr_target:` to
  # take the two questions apart.
  def review(config, client, mr_target: nil)
    client.mr_target = mr_target || config['target_branch'] || client.default_branch
    outcome(review_monitor(config, client))
  end

  def review_monitor(config, client)
    PipelineMonitor.allocate.tap do |mon|
      mon.instance_variable_set(:@client, client)
      mon.instance_variable_set(:@project_path, config['path'])
      mon.instance_variable_set(:@project_config, config)
      mon.instance_variable_set(:@logger, NullLogger.new)
      %i[log log_error].each { |m| mon.define_singleton_method(m) { |*| nil } }
      mon.define_singleton_method(:mr_review_timeout) { 600 }
      mon.define_singleton_method(:clone_and_checkout) { |dir, _| FileUtils.mkdir_p(dir) }
      stub_review_run!(mon)
    end
  end

  def stub_review_run!(mon)
    mon.define_singleton_method(:danger_claude_prompt) do |*_args, **_kwargs|
      File.write(mon.send(:review_contract_path, 7),
                 { verdict: 'approve', summary: '', findings: [] }.to_json)
      'ok'
    end
    mon.define_singleton_method(:publish_review) { |*| { posted: 0, demoted: 0 } }
  end

  def outcome(mon)
    mon.send(:review_with_skill, Ticket.new(4242, 7, 'autodev/issue-4242', 'fr'))
    'present'
  rescue MissingReviewSkillError
    'missing'
  end

  def clients(files) = [FakeGitlab.new(files: files), FakeGitlab.new(files: files)]

  def refs_of(client) = client.calls.filter_map { |(_kind, _arg, ref)| ref }.uniq
  def files_asked(client) = client.calls.select { |(kind, _, _)| kind == :get_file }.map { |(_, file, _)| file }

  # --- derived: no asker spells the question itself ------------------------

  # Every file that asks. Read off the tree, not listed: an asker is a file under
  # `app/` or `lib/` whose **code** mentions the shared module, minus the module
  # itself, which is where the answer is allowed to live. The two-element list
  # this used to be could not see a third asker, and Autodev #89 exists because
  # nobody saw the second one.
  def askers
    Dir[File.join(ROOT, '{app,lib}', '**', '*.rb')].reject { |path| path == MODULE_SOURCE }
                                                   .select { |path| code_of(path).include?('ReviewSkillSource') }
                                                   .sort
  end

  # The derivation must not be able to answer "nobody asks, nothing to check".
  # A rename, a moved file or a splitter that blanks too much would empty it in
  # silence, and every assertion below would pass over an empty set.
  def test_the_askers_are_found_in_the_tree
    found = askers

    [PROBE_SOURCE, REVIEWER_SOURCE].each do |source|
      assert_includes found, source, <<~MSG
        #{File.basename(source)} is not in the asker perimeter any more. Either it stopped
        asking the shared module — which is the whole defect — or this scan is broken and
        every assertion below has been passing over a set that does not contain it.
      MSG
    end
    assert_path_exists MODULE_SOURCE, 'the shared module moved; the scan excludes a path that no longer exists'
  end

  def test_no_asker_spells_the_question_itself
    askers.each do |source|
      spelled = OWNED_BY_THE_SHARED_MODULE.select { |token| code_of(source).include?(token) }

      assert_empty spelled, <<~MSG
        #{File.basename(source)} names #{spelled.join(', ')} itself. That is a second
        definition of "which revision decides the review skill, and what is asked
        about it" — the shape Autodev #89 exists to remove, and the shape Autodev #72
        (MrState) and Autodev #81 (skill_paths) each had to remove before it. Ask
        `ReviewSkillSource`.
      MSG
    end
  end

  # A **call**, not the name. Before this round the assertion was
  # `include?('ReviewSkillSource')` over a text that still carried trailing
  # comments, so a hand-written copy followed by `# ReviewSkillSource` satisfied
  # it — and did, for all seven tests here.
  def test_every_asker_routes_through_the_shared_module
    askers.each do |source|
      assert_match ROUTED_THROUGH, code_of(source),
                   "#{File.basename(source)} mentions the shared module without calling it"
    end
  end

  # The other end of the same rule: the module has to be where the answer lives.
  # An asker cannot be clean because the definition was emptied out from under it.
  # The ref half is not asserted as a spelling because the module does not spell
  # it either — it asks `TargetBranch`, and that delegation is Autodev #91's.
  def test_the_shared_module_is_where_the_question_is_answered
    code = code_of(MODULE_SOURCE)
    absent = ANSWERED_BY_THE_SHARED_MODULE.reject { |token| code.include?(token) }

    assert_empty absent, <<~MSG
      `ReviewSkillSource` no longer spells #{absent.join(', ')}, so every asker can be
      clean of it without the question having one answer. Whatever moved out has to
      be one definition somewhere else, and this file has to be asking it.
    MSG
    assert_match ASKS_TARGET_BRANCH, code,
                 'the ref half is nobody\'s: the shared module has stopped asking `TargetBranch` for it'
  end

  # --- behavioural: the same ref ------------------------------------------

  def test_both_askers_ask_about_the_configured_target_branch
    probed, reviewed = clients(STATES.fetch('the canonical layout on the target branch'))
    probe(project(target_branch: 'staging'), probed)
    review(project(target_branch: 'staging'), reviewed)

    assert_equal ['staging'], refs_of(probed)
    assert_equal refs_of(probed), refs_of(reviewed)
  end

  def test_both_askers_fall_back_to_the_repositorys_default_branch
    files = STATES.fetch('the canonical layout on the target branch')
    probed = FakeGitlab.new(files: files, default_branch: 'trunk')
    reviewed = FakeGitlab.new(files: files, default_branch: 'trunk')
    probe(project(target_branch: nil), probed)
    review(project(target_branch: nil), reviewed)

    assert_equal ['trunk'], refs_of(probed)
    assert_equal refs_of(probed), refs_of(reviewed)
  end

  # --- behavioural: the same layouts ---------------------------------------

  def test_both_askers_ask_about_the_same_layouts
    STATES.each_value do |files|
      probed, reviewed = clients(files)
      probe(project, probed)
      review(project, reviewed)

      assert_equal files_asked(probed), files_asked(reviewed)
    end
  end

  # --- behavioural: the same derogation ------------------------------------

  # `SkillsInjector` writes these into every clone itself. The probe answers
  # `present` without a request; the review has to agree, or a project declaring
  # `code-conventions` gets a green card and a failing review — today's defect
  # exactly inverted.
  def test_both_askers_take_the_same_self_injected_derogation
    config = project(skill: SkillsInjector::SKILL_NAMES.first)
    probed, reviewed = clients({})

    assert_equal %w[present present], [probe(config, probed)[:status], review(config, reviewed)]
    assert_equal [[], []], [probed.calls, reviewed.calls]
  end

  # --- the counter-example -------------------------------------------------

  # The property the whole fix is for, stated as an implication rather than as a
  # list: on a repository where the two questions have the same answer, whatever
  # GitLab holds, the probe's verdict and the review's outcome are the same word.
  # `present` on the card and `review_skill_missing` on the ticket cannot both be
  # true of it.
  #
  # The condition is stated because it is real and it is new. Until the round that
  # applied Autodev #91 here, both askers asked the configuration and the
  # agreement was unconditional. The review now asks the target the **merge
  # request** carries and the probe still asks the one the **configuration**
  # declares, so what holds is the implication above, over the states where the
  # two coincide — which is every project of the fleet as measured, is what the
  # fixture builds, and is what the production defect was about. Where they do not
  # coincide the two answers may legitimately differ, and the next test is that
  # case rather than a comment saying so.
  def test_the_two_verdicts_agree_wherever_the_two_targets_coincide
    STATES.each do |described, files|
      probed, reviewed = clients(files)

      assert_equal probe(project, probed)[:status], review(project, reviewed),
                   "the probe and the review disagree about #{described}"
    end
  end

  # The divergent case, pinned rather than described: one repository carrying the
  # declared skill on the configured target and not on the target its merge
  # request is going into. `present` on the health card and `review_skill_missing`
  # on the request are then **both correct** — they are answers to two different
  # questions, and a reader who takes the test above for an unconditional identity
  # would go looking for a bug that is not there.
  DIVERGENT_MR_TARGET = 'release/2027-q1'

  # One repository, the skill on `master` only, a merge request going into
  # something else.
  def divergent
    files = STATES.fetch('the canonical layout on the target branch')
    config = project(target_branch: 'master')
    probed = FakeGitlab.new(files: files, only_on: 'master')
    reviewed = FakeGitlab.new(files: files, only_on: 'master')
    [probe(config, probed)[:status], review(config, reviewed, mr_target: DIVERGENT_MR_TARGET), probed, reviewed]
  end

  def test_the_two_askers_ask_two_different_questions_when_the_answers_differ
    probed_status, reviewed_status, = divergent

    assert_equal 'present', probed_status, 'the configured target carries the skill, so the card is right'
    assert_equal 'missing', reviewed_status,
                 'the review must judge the branch its merge request is going into, not the configured one'
  end

  # And the mechanism behind it, so the test above cannot pass for another reason:
  # the two asked GitLab about different revisions.
  def test_the_two_askers_asked_about_different_refs
    _probed_status, _reviewed_status, probed, reviewed = divergent

    assert_equal ['master'], refs_of(probed)
    assert_includes refs_of(reviewed), DIVERGENT_MR_TARGET
  end

  private

  # Code only: a token named in a comment is prose about the shared module, not a
  # second definition of it. **Including a trailing comment**, which is the half
  # this used to keep — see the header.
  #
  # `uncommented`, not `blanked`: string literals stay. `project['target_branch']`
  # is a literal, and it is the offence — blanking literals here would hide the
  # very thing `OWNED_BY_THE_SHARED_MODULE` is a list of.
  def code_of(source) = RubySource.uncommented_file(source)
end
# rubocop:enable Metrics/ClassLength

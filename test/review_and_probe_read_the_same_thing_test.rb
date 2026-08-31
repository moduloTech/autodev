# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
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
#   * **derived**: neither asker spells the ref, the layouts or the
#     self-injected derogation itself. All three come from `ReviewSkillSource`,
#     so a change to any of them reaches both readers or neither;
#   * **behavioural**: over the same GitLab state, the two agree — same ref
#     asked about, same layouts asked about, same derogation — and a project the
#     probe calls `present` cannot produce `review_skill_missing`.
#
# The limit, stated rather than left implicit: the derived half reads code lines
# only (a full-line comment is not code), and it proves that these two askers
# share the definition, never that a third one added tomorrow will.
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

  PROBE_SOURCE = File.expand_path('../app/services/autodev/review_skill_probe.rb', __dir__)
  REVIEWER_SOURCE = File.expand_path('../lib/autodev/pipeline_monitor/skill_reviewer.rb', __dir__)
  # Spelling any of these in either asker is a second definition of the question.
  OWNED_BY_THE_SHARED_MODULE = %w[target_branch default_branch skill_paths SKILL_NAMES get_file].freeze

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

    attr_reader :calls

    def initialize(files: {}, default_branch: 'master')
      @files = files
      @default_branch = default_branch
      @calls = []
    end

    def project(path)
      @calls << [:project, path, nil]
      Repo.new(@default_branch)
    end

    def get_file(_path, file, ref)
      @calls << [:get_file, file, ref]
      raise not_found unless @files.key?(file)

      Struct.new(:file_path).new(file)
    end

    def commit(_path, ref)
      @calls << [:commit, nil, ref]
      Commit.new('deadbeef')
    end

    def tree(_path, options)
      @calls << [:tree, options[:path], options[:ref]]
      @files.keys.select { |file| file.start_with?("#{options[:path]}/") }
                 .map { |file| Blob.new('blob', file) }
    end

    def file_contents(_path, file, ref)
      @calls << [:file_contents, file, ref]
      @files.fetch(file)
    end

    private

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
  def review(config, client)
    mon = PipelineMonitor.allocate
    mon.instance_variable_set(:@client, client)
    mon.instance_variable_set(:@project_path, config['path'])
    mon.instance_variable_set(:@project_config, config)
    mon.instance_variable_set(:@logger, NullLogger.new)
    %i[log log_error].each { |m| mon.define_singleton_method(m) { |*| nil } }
    mon.define_singleton_method(:mr_review_timeout) { 600 }
    mon.define_singleton_method(:clone_and_checkout) { |dir, _| FileUtils.mkdir_p(dir) }
    stub_review_run!(mon)
    outcome(mon)
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

  # --- derived: neither asker spells the question itself -------------------

  def test_neither_asker_spells_the_question_itself
    [PROBE_SOURCE, REVIEWER_SOURCE].each do |source|
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

  def test_both_askers_route_through_the_shared_module
    [PROBE_SOURCE, REVIEWER_SOURCE].each do |source|
      assert_includes code_of(source), 'ReviewSkillSource', "#{File.basename(source)} does not ask the shared module"
    end
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
  # list: whatever GitLab holds, the probe's verdict and the review's outcome are
  # the same word. `present` on the card and `review_skill_missing` on the ticket
  # cannot both be true of one repository state.
  def test_the_probes_verdict_and_the_reviews_outcome_agree_on_every_state
    STATES.each do |described, files|
      probed, reviewed = clients(files)

      assert_equal probe(project, probed)[:status], review(project, reviewed),
                   "the probe and the review disagree about #{described}"
    end
  end

  private

  # Code lines only: a token named in a comment is prose about the shared module,
  # not a second definition of it.
  def code_of(source)
    File.readlines(source).reject { |line| line.strip.start_with?('#') }.join
  end
end
# rubocop:enable Metrics/ClassLength

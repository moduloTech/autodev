# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'autodev/pipeline_monitor'

# Autodev #89 and #91 cut the same case in opposite directions, and the visible
# strings claimed they were one (review round, constat 5).
#
# `ReviewSkillSource.ref_for` routed to `TargetBranch.for_fleet_scan` — question
# 1, the configuration — justified in the file by "a fleet scan holds no merge
# request". That is true of one of its two callers. The other is
# `SkillReviewer#prepare_review_clone`, which is handed an `Issue` and holds
# `issue.mr_iid`.
#
# Autodev #89's own argument does not reach this far either. "A merge request may
# modify the review skill and must not supply the rules that judge it" (the
# Autodev #79 ruling one layer up) excludes the **source** branch, and it does:
# nothing here ever reads `issue.branch_name`. It says nothing about preferring
# the *configuration's* target to the *merge request's*, because a merge request
# cannot modify its own target — GitLab records it, and retargeting is a human
# action on GitLab.
#
# So Autodev #91's rule carries: an existing merge request is judged against the
# branch it is going into. That is also the only reading under which the review is
# about the right thing — a merge request into `staging` has to be reviewed under
# `staging`'s conventions, whatever `master` happens to declare today.
#
# The probe keeps question 1, and correctly: it sweeps every project once per
# cycle with no merge request in hand, so the configuration *is* its answer. The
# two askers now agree wherever the configuration and the merge request agree,
# which is the whole fleet as measured on 01/09/2026 (30 open MRs, 30 on
# `master`), and differ exactly where they should.
#
# The strings said otherwise in both languages — "la branche cible du projet,
# celle qui fait foi pour la revue de %{mr_url}" and "c'est elle qui fait foi pour
# la revue, jamais la branche de la MR" — which is false on a merge request that
# targets something else. They are fixed with the code, in fr and en.
# rubocop:disable Metrics/ClassLength -- the ruling only reads whole: which ref the
# review asks about, which one the probe asks about, and what each of the two does
# when that ref is not there. Splitting them would put the rule and its
# counter-example in different files.
class TheReviewReadsTheMergeRequestsTargetTest < Minitest::Test
  include DatabaseTestHelper

  SKILL = 'mr-review'
  SKILLS_DIR = '.claude/skills'
  CANONICAL = "#{SKILLS_DIR}/#{SKILL}/SKILL.md".freeze
  PROJECT_PATH = 'modulosource/powerpanne/powerpanne'
  CONFIG_TARGET = 'master'
  MR_TARGET = 'staging'

  # `files` is { ref => { path => contents } }, so "which ref was asked about" is
  # answerable from the outcome as well as from the call log.
  class FakeGitlab
    Blob = Struct.new(:type, :path)
    Repo = Struct.new(:default_branch)
    Note = Struct.new(:id, :body)
    GlIssue = Struct.new(:labels, :id)
    Mr = Struct.new(:iid, :state, :target_branch)

    attr_reader :calls

    def initialize(files: {}, refs: nil, mr_target: MR_TARGET, default_branch: CONFIG_TARGET)
      @files = files
      @refs = refs || (files.keys + [default_branch]).uniq
      @mr_target = mr_target
      @default_branch = default_branch
      @calls = []
    end

    def merge_request(_path, iid)
      @calls << { kind: :merge_request, ref: nil }
      Mr.new(iid, 'opened', @mr_target)
    end

    def project(_path)
      @calls << { kind: :project, ref: nil }
      Repo.new(@default_branch)
    end

    def get_file(_path, file, ref)
      @calls << { kind: :get_file, file: file, ref: ref }
      raise not_found unless @files.fetch(ref, {}).key?(file)

      Struct.new(:file_path).new(file)
    end

    def commit(_path, ref)
      @calls << { kind: :commit, ref: ref }
      raise not_found unless @refs.include?(ref)

      Struct.new(:id).new('deadbeef')
    end

    def tree(_path, options)
      @calls << { kind: :tree, ref: options[:ref] }
      under = @files.fetch(options[:ref], {}).keys.select { |f| f.start_with?("#{options[:path]}/") }
      Gitlab::PaginatedResponse.new(under.map { |file| Blob.new('blob', file) })
    end

    def file_contents(_path, file, ref)
      @calls << { kind: :file_contents, file: file, ref: ref }
      @files.fetch(ref).fetch(file)
    end

    def issue(_path, _iid) = GlIssue.new(labels: ['Doing'], id: 1)
    def user = GlIssue.new(labels: [], id: 999)
    def edit_issue(_path, _iid, **_attrs) = GlIssue.new(labels: [], id: 1)
    def create_issue_note(_path, _iid, body) = Note.new(1, body)
    def issue_note(_path, _iid, note_id) = Note.new(note_id, '')
    def edit_issue_note(_path, _iid, _note_id, body) = Note.new(1, body)

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

  def setup
    setup_database
    @materialised = {}
  end

  def ticket = Ticket.new(4242, 7, 'autodev/issue-4242', 'fr')
  def work_dir = "/tmp/autodev_review_#{PROJECT_PATH.tr('/', '_')}_4242"

  # The two branches carry a *different* skill, so which one judged is readable
  # off the clone rather than only off the call log.
  def both_branches_carry_a_skill
    { MR_TARGET => { CANONICAL => '# the staging rules' },
      CONFIG_TARGET => { CANONICAL => '# the master rules' } }
  end

  def refs_asked(client) = client.calls.filter_map { |call| call[:ref] }.uniq

  # --- the ruling ----------------------------------------------------------

  def test_the_review_reads_the_skill_of_the_branch_the_merge_request_goes_into
    review(client: FakeGitlab.new(files: both_branches_carry_a_skill))

    assert_equal '# the staging rules', @materialised[CANONICAL]
  end

  def test_the_configured_target_is_not_asked_about_at_all
    client = FakeGitlab.new(files: both_branches_carry_a_skill)
    review(client: client)

    assert_equal [MR_TARGET], refs_asked(client)
  end

  # The case the fleet is in today: the configuration and the merge request agree,
  # so nothing moves. 30 of PowerPanne's 30 open merge requests on 01/09/2026.
  def test_a_merge_request_that_agrees_with_the_configuration_is_unaffected
    client = FakeGitlab.new(files: { CONFIG_TARGET => { CANONICAL => '# the master rules' } },
                            mr_target: CONFIG_TARGET)
    review(client: client)

    assert_equal '# the master rules', @materialised[CANONICAL]
  end

  # The skill is on the branch the merge request goes into and nowhere else — the
  # inverse of the case Autodev #89 fixed, and the one that used to stop the line.
  def test_a_skill_only_on_the_merge_requests_target_is_found
    review(client: FakeGitlab.new(files: { MR_TARGET => { CANONICAL => '# the staging rules' } }))

    assert_equal '# the staging rules', @materialised[CANONICAL]
  end

  # And the give-up names the ref that actually decided, which is the whole point
  # of Autodev #89 carrying `ref` on that error: an operator told to add the skill
  # to `master` when the review reads `staging` fixes nothing.
  def test_the_missing_skill_error_names_the_merge_requests_target
    client = FakeGitlab.new(files: { CONFIG_TARGET => { CANONICAL => '# the master rules' } },
                            refs: [MR_TARGET, CONFIG_TARGET])
    error = assert_raises(MissingReviewSkillError) { review(client: client) }

    assert_equal MR_TARGET, error.ref
  end

  # --- the probe keeps question 1 ------------------------------------------

  # It sweeps the configured fleet project by project and holds no merge request,
  # so the configuration is its answer — and it must not start reading merge
  # requests, which is a per-MR value a per-project pass cannot have.
  def test_the_probe_still_asks_about_the_configured_target
    client = FakeGitlab.new(files: both_branches_carry_a_skill)
    Autodev::ReviewSkillProbe.probe!(config: {}, projects: [project_config], client: client,
                                     logger: NullLogger.new)

    assert_equal [CONFIG_TARGET], refs_asked(client)
  end

  def test_the_probe_reads_no_merge_request
    client = FakeGitlab.new(files: both_branches_carry_a_skill)
    Autodev::ReviewSkillProbe.probe!(config: {}, projects: [project_config], client: client,
                                     logger: NullLogger.new)

    assert_empty(client.calls.select { |call| call[:kind] == :merge_request })
  end

  # --- the neighbouring lie: `confirm_ref!` ---------------------------------

  # Autodev #91 overrode `describe` on `MissingTargetBranchError` precisely so a
  # branch that is gone would not be reported as GitLab going dark. The
  # neighbouring case in #89 kept doing exactly that: a `target_branch` that does
  # not exist reached the operator as "GitLab did not answer the review_skill_ref
  # read: 404 Commit Not Found", and GitLab had answered perfectly well.
  def test_a_ref_that_does_not_exist_does_not_accuse_gitlab
    client = FakeGitlab.new(files: {}, refs: [CONFIG_TARGET])

    error = assert_raises(MissingTargetBranchError) { review(client: client) }

    assert_equal MR_TARGET, error.branch
    refute_includes error.message, 'GitLab did not answer'
  end

  # And it is evidence, so the bound of `MissingBaseBound` applies to it: a ref
  # that is not on the repository will not appear on its own.
  def test_a_ref_that_does_not_exist_is_evidence
    client = FakeGitlab.new(files: {}, refs: [CONFIG_TARGET])
    error = assert_raises(MissingTargetBranchError) { review(client: client) }

    assert_predicate error, :confirmed?
  end

  # The control that keeps it from becoming a verdict on an outage: a read that
  # failed for any other reason is still `ApiUnavailableError` and still not a
  # `MissingTargetBranchError`.
  def test_an_unreadable_ref_check_is_still_an_outage
    client = ExplodingCommit.new(files: {}, refs: [MR_TARGET])

    error = assert_raises(ApiUnavailableError) { review(client: client) }

    refute_kind_of MissingTargetBranchError, error
  end

  class ExplodingCommit < FakeGitlab
    def commit(_path, _ref)
      request = Struct.new(:base_uri, :path).new('https://gitlab.example', '/api/v4')
      raise Gitlab::Error::InternalServerError,
            Struct.new(:code, :parsed_response, :request).new(500, {}, request)
    end
  end

  private

  def project_config
    { 'path' => PROJECT_PATH, 'target_branch' => CONFIG_TARGET, 'review_skill' => SKILL }
  end

  def review(client:)
    monitor(client).send(:review_with_skill, ticket)
  end

  def monitor(client)
    PipelineMonitor.allocate.tap do |mon|
      mon.send(:init_runner, client: client, config: { 'gitlab_url' => 'https://gitlab.example' },
                             project_config: project_config, logger: NullLogger.new, token: 'tok')
      %i[log log_error].each { |m| mon.define_singleton_method(m) { |*| nil } }
      mon.define_singleton_method(:mr_review_timeout) { 600 }
      mon.define_singleton_method(:clone_and_checkout) { |dir, _b| FileUtils.mkdir_p(dir) }
      stub_danger_claude!(mon)
      mon.define_singleton_method(:publish_review) { |*| { posted: 0, demoted: 0 } }
    end
  end

  def stub_danger_claude!(mon)
    photograph = ->(dir) { @materialised = snapshot(dir) }
    mon.define_singleton_method(:danger_claude_prompt) do |dir, *_args, **_kwargs|
      photograph.call(dir)
      File.write(mon.send(:review_contract_path, 7),
                 { verdict: 'approve', summary: '', findings: [] }.to_json)
      'ok'
    end
  end

  def snapshot(dir)
    Dir.glob(File.join(dir, '**', '*'), File::FNM_DOTMATCH)
       .select { |path| File.file?(path) }
       .to_h { |path| [path.delete_prefix("#{dir}/"), File.read(path)] }
  end
end
# rubocop:enable Metrics/ClassLength

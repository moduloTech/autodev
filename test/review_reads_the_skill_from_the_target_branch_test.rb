# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'autodev/pipeline_monitor'

# The review runs under the review skill of the branch that **decides**, not of
# the branch it is judging (Autodev #89).
#
# Until this fix the review step and the start-up probe read two different
# branches and nothing said so. `SkillReviewer` cloned `issue.branch_name` — the
# MR's *source* branch, and `--depth 1 --branch <b>` is a single-branch clone, so
# nothing else is even fetchable — and looked for the declared skill in that
# clone. `Autodev::ReviewSkillProbe` (Autodev #81) asked GitLab about the
# project's `target_branch`. Measured on production on 31/08/2026: 13 of the 23
# branches of the ticket-88 population carry neither `.claude/skills/mr-review/`
# nor the flat layout, while the probe answered "2 declared, 2 present" — and it
# was right. Request powerpanne 15842 was abandoned under `review_skill_missing`
# on 28/08 for exactly that: a reason that named the correct immediate cause and
# invited a false conclusion, since the project does declare a skill and the
# skill does exist.
#
# Two rulings are pinned here and neither is negotiable:
#
#   * **the target wins, always** (the Autodev #79 argument one layer up: a
#     branch may not supply the rules that judge it). An exception for "if the
#     branch carries the skill, use the branch's" would reinstate the defect for
#     the 13 branches that carry a stale `review` copy;
#   * **a failed read is never a verdict** (Autodev #67). Every GitLab read here
#     goes through `GitlabHelpers.answer`, so an outage raises
#     `ApiUnavailableError` — already handled by `Reviewer#launch_review`, which
#     hands the row back to `checking_pipeline` and re-raises — and can never
#     produce `MissingReviewSkillError`, which is terminal.
#
# rubocop:disable Metrics/ClassLength -- one file per behaviour, and this
# behaviour only reads whole: which ref is asked about, what is materialised from
# it, what happens when it is not there, and what happens when the read fails.
# Same call as ReviewSkillProbeTest.
class ReviewReadsTheSkillFromTheTargetBranchTest < Minitest::Test
  include DatabaseTestHelper

  SKILL = 'mr-review'
  SKILLS_DIR = '.claude/skills'
  CANONICAL = "#{SKILLS_DIR}/#{SKILL}/SKILL.md".freeze
  # The flat layout `SkillsInjector.migrate_legacy_skills` moves into the one
  # above, inside the clone, before `skill_available?` looks.
  FLAT = "#{SKILLS_DIR}/#{SKILL}.md".freeze
  # The skill is multi-file: powerpanne's `mr-review` carries
  # `references/posting.md` + `references/project-checklist.md`, and prepare-mr
  # carries `references/divergences.md`. A single `get_file` of `SKILL.md` would
  # materialise a skill referencing files that are not there.
  REFERENCE = "#{SKILLS_DIR}/#{SKILL}/references/posting.md".freeze
  STALE = "#{SKILLS_DIR}/#{SKILL}/references/removed-on-the-target.md".freeze

  PROJECT_PATH = 'modulosource/powerpanne/powerpanne'

  TARGET_SKILL = { CANONICAL => "# #{SKILL} (target branch)", REFERENCE => 'how to post' }.freeze

  # Answers the four reads this path makes, records every one, and raises where
  # asked to. `clone` is absent on purpose: nothing here may shell out to git.
  class FakeGitlab
    Blob = Struct.new(:type, :path, :name)
    Repo = Struct.new(:default_branch)
    Commit = Struct.new(:id)
    Note = Struct.new(:id, :body)
    GlIssue = Struct.new(:labels, :id)

    attr_reader :calls, :notes, :edits

    # `files` is { ref => { repository path => contents } }; `refs` the branches
    # the repository has (defaults to the ones `files` names, plus the default
    # branch); `failing` the read kind that blows up.
    def initialize(files: {}, refs: nil, default_branch: 'master', failing: nil,
                   error: Gitlab::Error::InternalServerError)
      @files = files
      @refs = refs || (files.keys + [default_branch]).uniq
      @default_branch = default_branch
      @failing = failing
      @error = error
      @calls = []
      @notes = []
      @edits = []
    end

    def project(path)
      record(:project, path, nil, nil)
      Repo.new(@default_branch)
    end

    def get_file(path, file, ref)
      record(:get_file, path, file, ref)
      raise not_found unless on_ref?(ref, file)

      Struct.new(:file_path).new(file)
    end

    def commit(path, ref)
      record(:commit, path, nil, ref)
      raise not_found unless @refs.include?(ref)

      Commit.new('deadbeef')
    end

    def tree(path, options)
      record(:tree, path, options[:path], options[:ref])
      under = paths_on(options[:ref]).select { |file| file.start_with?("#{options[:path]}/") }
      raise not_found if under.empty?

      under.map { |file| Blob.new('blob', file, File.basename(file)) }
    end

    def file_contents(path, file, ref)
      record(:file_contents, path, file, ref)
      raise not_found unless on_ref?(ref, file)

      @files.fetch(ref).fetch(file)
    end

    # --- the issue writes `log_activity` performs on the way in --------------

    def issue(_path, _iid) = GlIssue.new(labels: ['Doing'], id: 1)
    def user = GlIssue.new(labels: [], id: 999)

    def edit_issue(_path, iid, **attrs)
      @edits << [iid, attrs]
      GlIssue.new(labels: [], id: 1)
    end

    def create_issue_note(_path, _iid, body)
      @notes << body
      Note.new(@notes.size, body)
    end

    def issue_note(_path, _iid, note_id) = Note.new(note_id, @notes.last.to_s)

    def edit_issue_note(_path, _iid, _note_id, body)
      @notes[-1] = body
      Note.new(1, body)
    end

    private

    def record(kind, path, file, ref)
      @calls << { kind: kind, path: path, file: file, ref: ref }
      raise @error, fake_response(500) if @failing == kind
    end

    def paths_on(ref) = @files.fetch(ref, {}).keys
    def on_ref?(ref, file) = @files.fetch(ref, {}).key?(file)
    def not_found = Gitlab::Error::NotFound.new(fake_response(404))

    # The shape `Gitlab::Error::ResponseError#initialize` reads to build its
    # message: the status, the parsed body, and the request's base_uri + path.
    def fake_response(code)
      request = Struct.new(:base_uri, :path).new('https://gitlab.example', '/api/v4')
      Struct.new(:code, :parsed_response, :request).new(code, {}, request)
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

  def project_config(target_branch:, skill:)
    { 'path' => PROJECT_PATH, 'target_branch' => target_branch, 'review_skill' => skill }
  end

  # Everything below `review_with_skill` that is not this file's subject is
  # stubbed; everything the ticket is about — the ref, the reads, the overlay —
  # is the real code. `danger_claude_prompt` is where the work directory is
  # photographed, because the `ensure` deletes it on the way out.
  def monitor(client:, target_branch: 'master', skill: SKILL, branch_files: {})
    PipelineMonitor.allocate.tap do |mon|
      mon.send(:init_runner, client: client, config: { 'gitlab_url' => 'https://gitlab.example' },
                             project_config: project_config(target_branch: target_branch, skill: skill),
                             logger: NullLogger.new, token: 'tok')
      %i[log log_error].each { |m| mon.define_singleton_method(m) { |*| nil } }
      mon.define_singleton_method(:mr_review_timeout) { 600 }
      stub_clone!(mon, branch_files)
      stub_danger_claude!(mon)
      mon.define_singleton_method(:publish_review) { |*| { posted: 0, demoted: 0 } }
    end
  end

  def stub_clone!(mon, branch_files)
    mon.define_singleton_method(:clone_and_checkout) do |dir, _branch|
      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p(dir)
      branch_files.each do |rel, body|
        FileUtils.mkdir_p(File.join(dir, File.dirname(rel)))
        File.write(File.join(dir, rel), body)
      end
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

  def declared_skill_files
    @materialised.select { |path, _| path.start_with?("#{SKILLS_DIR}/#{SKILL}") }
  end

  def review(**) = monitor(**).send(:review_with_skill, ticket)

  # --- the defect this file replays ----------------------------------------

  # The red test. 13 of the 23 production branches look exactly like this: the
  # skill is on the target branch and nowhere on the branch under review, and the
  # review used to raise `MissingReviewSkillError` and give the request up.
  def test_a_branch_without_the_skill_is_reviewed_when_the_target_branch_carries_it
    outcome = review(client: FakeGitlab.new(files: { 'master' => TARGET_SKILL }))

    assert_same true, outcome
  end

  # --- which ref decides ---------------------------------------------------

  def test_the_ref_asked_about_is_the_configured_target_branch
    client = FakeGitlab.new(files: { 'master' => TARGET_SKILL })
    review(client: client, target_branch: 'master', branch_files: { CANONICAL => 'stale' })

    assert_equal ['master'], client.calls.filter_map { |call| call[:ref] }.uniq
  end

  # Never the MR's own target: no reader of `mr.target_branch` exists anywhere in
  # the tree, `MrManager#create_mr` and `RepoRebaser` both read the config, and
  # the probe is per project once per cycle, so it structurally cannot read a
  # per-MR value. One definition or the two diverge again.
  def test_the_branch_under_review_is_never_the_ref
    client = FakeGitlab.new(files: { 'master' => TARGET_SKILL })
    review(client: client, branch_files: { CANONICAL => 'stale' })

    refute_includes client.calls.filter_map { |call| call[:ref] }, 'autodev/issue-4242'
  end

  # Unset means "the repository's default branch", the fallback `MrManager` and
  # `RepoRebaser` already take — and it is read once, not once per question.
  def test_with_no_target_branch_configured_the_repository_default_branch_decides
    client = FakeGitlab.new(files: { 'trunk' => TARGET_SKILL }, default_branch: 'trunk')
    review(client: client, target_branch: nil)

    assert_equal ['trunk'], client.calls.filter_map { |call| call[:ref] }.uniq
    assert_equal(1, client.calls.count { |call| call[:kind] == :project })
  end

  # --- what is materialised from it ----------------------------------------

  def test_the_whole_skill_subtree_is_materialised_not_only_skill_md
    review(client: FakeGitlab.new(files: { 'master' => TARGET_SKILL }))

    assert_equal [CANONICAL, REFERENCE].sort, declared_skill_files.keys.sort
  end

  def test_the_materialised_files_carry_the_target_branchs_contents
    review(client: FakeGitlab.new(files: { 'master' => TARGET_SKILL }))

    assert_equal TARGET_SKILL, declared_skill_files
  end

  # The flat layout is an accepted repository shape (Autodev #81, fix round 2):
  # it is written into the clone and `SkillsInjector.migrate_legacy_skills` moves
  # it to the canonical one before `skill_available?` looks. The overlay runs
  # *before* `inject` precisely so that invariant keeps holding.
  def test_a_flat_layout_on_the_target_branch_is_still_available_after_injection
    outcome = review(client: FakeGitlab.new(files: { 'master' => { FLAT => '# flat mr-review' } }))

    assert_same true, outcome
    assert_equal '# flat mr-review', @materialised[CANONICAL]
  end

  # Parity with `ReviewSkillProbe`'s own derogation: autodev writes these four
  # into every clone itself, so the repository is not asked about them. Without
  # it a project declaring `code-conventions` would get a green probe and a
  # failing review — today's defect exactly inverted.
  def test_a_skill_autodev_injects_itself_costs_no_request
    client = FakeGitlab.new
    outcome = review(client: client, skill: SkillsInjector::SKILL_NAMES.first)

    assert_same true, outcome
    assert_empty client.calls
  end

  # --- the target wins, always ---------------------------------------------

  def test_the_target_branchs_version_wins_over_the_branch_under_reviews
    review(client: FakeGitlab.new(files: { 'master' => TARGET_SKILL }),
           branch_files: { CANONICAL => "# #{SKILL} (the branch under review)" })

    assert_equal "# #{SKILL} (target branch)", @materialised[CANONICAL]
  end

  # Deleting `SKILL.md` alone is not enough: the skill is multi-file, so a
  # `references/` file the target branch no longer has would be read alongside
  # the target's own `SKILL.md`. The declared skill's whole directory goes.
  def test_a_reference_file_only_the_branch_under_review_has_is_dropped
    review(client: FakeGitlab.new(files: { 'master' => TARGET_SKILL }),
           branch_files: { CANONICAL => 'stale', STALE => 'stale reference' })

    refute_includes declared_skill_files.keys, STALE
  end

  # The counter-example to any "if the branch has it, trust the branch" shortcut:
  # a branch carrying a stale copy of a skill the target does not declare must
  # still stop the line, or an MR gets to supply the rules that judge it.
  def test_the_branch_under_reviews_own_copy_does_not_answer_for_the_target
    client = FakeGitlab.new(files: { 'master' => {} })

    assert_raises(MissingReviewSkillError) do
      review(client: client, branch_files: { CANONICAL => '# whatever I like' })
    end
  end

  # --- the cost ------------------------------------------------------------

  # One `get_file` locates the layout (the Autodev #81 question, shared with the
  # probe), one `tree` enumerates the subtree, one `file_contents` per blob.
  def test_the_cost_is_one_locate_one_tree_and_one_read_per_blob
    client = FakeGitlab.new(files: { 'master' => TARGET_SKILL })
    review(client: client)

    assert_equal([[:get_file, CANONICAL], [:tree, "#{SKILLS_DIR}/#{SKILL}"],
                  [:file_contents, CANONICAL], [:file_contents, REFERENCE]],
                 client.calls.map { |call| [call[:kind], call[:file]] })
  end

  # --- the skill really is absent from the target --------------------------

  def test_a_skill_on_neither_layout_of_the_target_branch_stops_the_line
    client = FakeGitlab.new(files: { 'master' => {} })
    error = assert_raises(MissingReviewSkillError) { review(client: client) }

    assert_equal [SKILL, CANONICAL], [error.skill, error.relative_path]
  end

  def test_the_missing_skill_error_names_the_ref_that_decided
    client = FakeGitlab.new(files: { 'master' => {} })
    error = assert_raises(MissingReviewSkillError) { review(client: client) }

    assert_equal 'master', error.ref
    assert_includes error.message, 'master'
  end

  def test_both_layouts_are_asked_about_before_the_line_is_stopped
    client = FakeGitlab.new(files: { 'master' => {} })
    assert_raises(MissingReviewSkillError) { review(client: client) }

    assert_equal([CANONICAL, FLAT], client.calls.select { |c| c[:kind] == :get_file }.map { |c| c[:file] })
  end

  # --- a failed read is never a verdict ------------------------------------

  # The trap Autodev #81 already carried and this fix inherits: GitLab answers
  # `404 Commit Not Found` for a ref that does not exist and `404 File Not Found`
  # for a file that does not, and **both are a `Gitlab::Error::NotFound`**. A
  # configured `target_branch` that has been deleted or renamed would therefore
  # read as "the skill is missing" and put the blame on the configuration.
  # Decision taken: abort, the line waits.
  def test_a_configured_ref_that_does_not_exist_aborts_rather_than_accusing
    client = FakeGitlab.new(files: {}, refs: ['staging'])

    assert_raises(ApiUnavailableError) { review(client: client, target_branch: 'master') }
  end

  def test_the_ref_is_only_confirmed_when_the_line_is_about_to_be_stopped
    client = FakeGitlab.new(files: { 'master' => TARGET_SKILL })
    review(client: client)

    assert_empty(client.calls.select { |call| call[:kind] == :commit })
  end

  def test_a_locate_error_that_is_not_a_notfound_aborts_instead_of_accusing
    client = FakeGitlab.new(files: { 'master' => TARGET_SKILL }, failing: :get_file)

    assert_raises(ApiUnavailableError) { review(client: client) }
  end

  def test_a_tree_error_aborts_instead_of_accusing
    client = FakeGitlab.new(files: { 'master' => TARGET_SKILL }, failing: :tree)

    assert_raises(ApiUnavailableError) { review(client: client) }
  end

  def test_a_file_contents_error_after_a_successful_tree_aborts_too
    client = FakeGitlab.new(files: { 'master' => TARGET_SKILL }, failing: :file_contents)

    assert_raises(ApiUnavailableError) { review(client: client) }
  end

  def test_a_default_branch_read_that_failed_aborts_instead_of_accusing
    client = FakeGitlab.new(files: { 'master' => TARGET_SKILL }, failing: :project)

    assert_raises(ApiUnavailableError) { review(client: client, target_branch: nil) }
  end

  # `Reviewer#launch_review` already answers `ApiUnavailableError` (Autodev #74,
  # fix round 2): the row goes back to `checking_pipeline` through `resume_watch`
  # with neither counter touched, and the error is re-raised so the poll still
  # aborts at `PipelineMonitor#check`'s boundary. That is why the API route needed
  # no new recovery branch — but it is only true if the read raises, which is what
  # this pins end to end.
  def test_an_aborted_read_returns_the_row_to_the_watch_with_the_counters_intact
    row = reviewing_issue
    mon = monitor(client: FakeGitlab.new(files: { 'master' => TARGET_SKILL }, failing: :tree))

    assert_raises(ApiUnavailableError) { mon.send(:launch_review, row) }
    assert_equal ['checking_pipeline', 0, 0],
                 [row.reload.status, row.review_count, row.review_failure_count]
  end

  def test_an_aborted_read_never_flags_the_row_for_attention
    row = reviewing_issue
    mon = monitor(client: FakeGitlab.new(files: { 'master' => TARGET_SKILL }, failing: :file_contents))

    assert_raises(ApiUnavailableError) { mon.send(:launch_review, row) }
    assert_nil row.reload.attention_reason
  end

  # --- the clone is disposable, on every route out -------------------------

  def test_the_review_clone_is_removed_after_a_review_from_the_target_branch
    review(client: FakeGitlab.new(files: { 'master' => TARGET_SKILL }))

    refute_path_exists work_dir
  end

  def test_the_review_clone_is_removed_when_the_target_branch_has_no_skill
    assert_raises(MissingReviewSkillError) { review(client: FakeGitlab.new(files: { 'master' => {} })) }

    refute_path_exists work_dir
  end

  def test_the_review_clone_is_removed_when_a_read_aborted_the_review
    client = FakeGitlab.new(files: { 'master' => TARGET_SKILL }, failing: :file_contents)
    assert_raises(ApiUnavailableError) { review(client: client) }

    refute_path_exists work_dir
  end

  def test_the_review_clone_is_removed_when_the_configured_ref_does_not_exist
    client = FakeGitlab.new(files: {}, refs: ['staging'])
    assert_raises(ApiUnavailableError) { review(client: client, target_branch: 'master') }

    refute_path_exists work_dir
  end

  private

  def reviewing_issue
    Issue.create!(project_path: PROJECT_PATH, issue_iid: 4242, mr_iid: 7,
                  mr_url: 'https://gitlab.example/mr/7', issue_author_id: 42,
                  status: 'reviewing', review_count: 0, review_failure_count: 0, locale: 'fr')
  end
end
# rubocop:enable Metrics/ClassLength

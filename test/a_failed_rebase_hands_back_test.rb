# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'autodev/pipeline_monitor'
require 'autodev/mr_fixer'
require 'autodev/issue_processor'

# Autodev #138 — a rebase that cannot be completed stops the line and hands it
# back.
#
# `RepoRebaser` answered `:failed` and all three of its callers discarded it, so
# the implementation, the discussion fixes and the pipeline fixes ran on a base
# the target had left behind — and the review that followed judged that base.
# Measured on powerpanne 12935 (09/10/2026): `Rebase --continue failed; aborting
# rebase. Output: app/controllers/companies/sites_controller.rb: needs merge`, then
# an implementation pushed on a base 865 commits behind `master`, and a review that
# asserted that a class the reviewer had asked for did not exist.
#
# Every test below runs the real git sequence on a repository on disk whose
# autodev branch and target edit the same line, and stubs only danger-claude (which
# "resolves" nothing) and the clone URL. The conflict is git's, not a stub's.
# rubocop:disable Metrics/ClassLength -- three boundaries share one fixture and one
# GitLab stub, and the property is that they agree.
class AFailedRebaseHandsBackTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_PATH = 'modulosource/powerpanne/powerpanne'
  TARGET = 'master'
  BRANCH = 'autodev/12935-parc'
  CONFLICTED = 'app/controllers/companies/sites_controller.rb'

  FakeMr = Struct.new(:iid, :state, :target_branch, :head_pipeline)
  FakePipeline = Struct.new(:id, :status)
  Discussion = Struct.new(:id, :notes)
  DiscussionNote = Struct.new(:body, :position, :created_at)

  # The GitLab half: the merge request the poll and the fix read their base from,
  # the jobs a red pipeline names, and every write the stop performs.
  class StubClient
    Note = Struct.new(:id, :body)
    GlIssue = Struct.new(:labels, :id, :state, :title, :description, :assignees)

    attr_reader :issue_notes_posted, :mr_notes, :edits

    def initialize
      @issue_notes_posted = []
      @mr_notes = []
      @edits = []
    end

    def merge_request(_path, iid)
      AFailedRebaseHandsBackTest::FakeMr.new(iid, 'opened', TARGET,
                                             AFailedRebaseHandsBackTest::FakePipeline.new(9, 'failed'))
    end

    def pipelines(_path, **_opts) = []

    def pipeline_jobs(_path, _pid, **_opts)
      [{ 'name' => 'rspec', 'stage' => 'test', 'status' => 'failed',
         'allow_failure' => false, 'failure_reason' => 'script_failure' }]
    end

    def merge_request_discussions(_path, _iid, **_opts) = FakePaginated.new([])
    def issue(_path, iid) = GlIssue.new(['Doing'], iid, 'opened', 'Parc', 'body', [])
    def issue_notes(_path, _iid, **_opts) = FakePaginated.new([])
    def issue_links(_path, _iid) = []
    def user = Struct.new(:id, :username).new(999, 'autodev')

    def edit_issue(_path, iid, **attrs)
      @edits << [iid, attrs]
      GlIssue.new([], 1, 'opened', 'Parc', 'body', Array(attrs[:assignee_ids]).map { |id| { 'id' => id } })
    end

    def create_issue_note(_path, _iid, body)
      @issue_notes_posted << body
      Note.new(@issue_notes_posted.size, body)
    end

    # Notes are addressed by id (1-based position), so the activity note being
    # rewritten in place never overwrites the abandon comment posted after it.
    def issue_note(_path, _iid, note_id) = Note.new(note_id, @issue_notes_posted[note_id - 1].to_s)

    def edit_issue_note(_path, _iid, note_id, body)
      @issue_notes_posted[note_id - 1] = body
      Note.new(note_id, body)
    end

    def create_merge_request_note(_path, iid, body)
      @mr_notes << [iid, body]
      Note.new(@mr_notes.size, body)
    end
  end

  class FakePaginated
    def initialize(items) = @items = items
    def auto_paginate = @items
    def each(&) = @items.each(&)
  end

  class NullLogger
    %i[info warn error debug].each { |level| define_method(level) { |*, **| nil } }
  end

  def setup
    setup_database
    @tmpdir = Dir.mktmpdir('failed_rebase_test')
    @bare = build_conflicting_origin
    @pushed = []
    @prompts = []
    @reviews = 0
    @implementations = 0
  end

  def teardown = FileUtils.rm_rf(@tmpdir)

  # --- 1. the discussion fix ------------------------------------------------

  # The motivating case's third occurrence (10/10, 04:02, round 2): no thread is
  # corrected on the stale base, nothing is pushed, and the line is handed back
  # under a reason that names the cause.
  def test_the_discussion_fix_stops_and_hands_back # rubocop:disable Minitest/MultipleAssertions
    row = fixing_issue
    fix(row)
    row.reload

    assert_equal %w[done rebase_conflict], [row.status, row.attention_reason]
    assert row.needs_attention
    assert_empty @pushed, 'nothing may be pushed from a round whose rebase failed'
    assert_equal 1, @prompts.size, 'only the conflict resolution may reach danger-claude, no fix prompt'
    assert_includes @prompts.first, 'conflits'
    assert_equal 0, row.fix_round, 'a round that never reached a correction is not counted'
  end

  # The reviewer reads the merge request: that is where the files are named.
  def test_the_merge_request_is_told_which_files_conflict # rubocop:disable Minitest/MultipleAssertions
    client = fix(fixing_issue)

    assert_equal [8], client.mr_notes.map(&:first), 'one comment, on this merge request'
    body = client.mr_notes.first.last

    assert_includes body, "`#{CONFLICTED}`"
    refute_includes body, 'needs merge', "git's --continue output is logged, never published"
    assert_includes body, "origin/#{TARGET}"
  end

  # The requester reads the ticket, and the ticket goes back to them.
  def test_the_ticket_names_the_files_and_goes_back_to_its_author
    client = fix(fixing_issue)

    assert(client.issue_notes_posted.any? { |n| n.include?(CONFLICTED) && n.include?('label de depart') })
    assert_includes client.edits.map { |(_iid, attrs)| attrs[:assignee_ids] }, [42]
  end

  # The ticket's last requirement: the review may not judge a base whose rebase
  # failed. The review is launched only from `checking_pipeline`, by
  # `dispatch_pipelines`, whose population is `IssueProcessJob::DISPATCHED_FROM`'s
  # `:check_pipeline` entry — and `IssueProcessJob#perform` refuses any row outside
  # it. A stopped row is in no such population, on either path that rebases an
  # existing merge request, so no review ever runs on what the failed round left.
  def test_no_review_can_follow_a_stopped_round
    fix(fixing_issue)
    poll(watched_issue)

    stopped = Issue.where(attention_reason: 'rebase_conflict')

    assert_equal 2, stopped.count
    assert_empty stopped.where(status: IssueProcessJob::DISPATCHED_FROM[:check_pipeline])
  end

  # --- 2. the pipeline fix --------------------------------------------------

  def test_the_pipeline_fix_stops_and_hands_back # rubocop:disable Minitest/MultipleAssertions
    row = watched_issue
    client = poll(row)
    row.reload

    assert_equal %w[done rebase_conflict], [row.status, row.attention_reason]
    assert_empty @pushed
    assert_equal 1, @prompts.size, 'only the conflict resolution may reach danger-claude, no fix prompt'
    assert_equal 1, client.mr_notes.size
    assert_includes client.mr_notes.first.last, CONFLICTED
  end

  # Neither `handle_failure_error` (which would park the row in `error` and retry
  # into the same conflict) nor the stagnation counter sees it.
  def test_the_pipeline_stop_is_neither_an_error_nor_a_counted_attempt
    row = watched_issue
    poll(row)
    row.reload

    assert_nil row.error_message
    assert_nil row.next_retry_at
    refute_includes row.stagnation_signatures.to_s, 'pipeline', 'the stop may not count as a fix attempt'
  end

  # --- 3. the re-implementation on a reused branch ---------------------------

  # The motivating case's first occurrence (09/10, 12:30): the implementation was
  # pushed at 12:42 on the stale base. It is never started now, and the row stops
  # from `cloning`, which is where the rebase happens.
  def test_a_reimplementation_stops_before_implementing # rubocop:disable Minitest/MultipleAssertions
    row = pending_issue(mr_iid: 7)
    client = process(row)
    row.reload

    assert_equal %w[done rebase_conflict], [row.status, row.attention_reason]
    assert_equal 0, @implementations, 'nothing may be implemented on the stale base'
    assert_empty @pushed
    assert_nil row.error_message, 'a failed rebase is not an error to retry into the same conflict'
    assert_equal 1, client.mr_notes.size
  end

  # A branch the previous run pushed before `create_merge_request`: there is no
  # merge request to comment on, and the ticket says it all.
  def test_without_a_merge_request_only_the_ticket_is_told
    row = pending_issue(mr_iid: nil)
    client = process(row)

    assert_equal %w[done rebase_conflict], [row.reload.status, row.attention_reason]
    assert_empty client.mr_notes
    assert(client.issue_notes_posted.any? { |n| n.include?(CONFLICTED) })
  end

  # --- 4. what the stop itself decides --------------------------------------

  # A danger-claude crash during the resolution has said nothing about the
  # conflict: the row takes the path's usual failure (`error`), not a hand-back.
  def test_a_crash_during_the_resolution_is_not_a_hand_back
    row = fixing_issue
    @claude_error = ImplementationError.new('container refused')
    client = fix(row)
    row.reload

    assert_equal ['error', nil], [row.status, row.attention_reason]
    assert_empty client.mr_notes
  end

  def test_a_crash_during_the_pipeline_resolution_is_not_a_hand_back
    row = watched_issue
    @claude_error = ImplementationError.new('container refused')
    poll(row)

    assert_equal ['error', nil], [row.reload.status, row.attention_reason]
  end

  # git can refuse with nothing left unmerged: still a stop, and the comments say
  # so rather than printing an empty list.
  def test_no_file_listed_is_said_on_both_comments # rubocop:disable Minitest/MultipleAssertions
    row = fixing_issue
    client = stop(row, [])
    said = Locales.t(:rebase_conflict_no_files, locale: :fr)

    assert_equal 'rebase_conflict', row.reload.attention_reason
    assert_equal '', row.attention_detail
    assert_includes client.mr_notes.first.last, said
    assert(client.issue_notes_posted.any? { |n| n.include?(said) })
  end

  # The `/errors` card carries the first five paths; the comments carry them all.
  def test_the_detail_is_bounded_and_the_comments_are_not
    files = (1..7).map { |n| "app/f#{n}.rb" }
    client = stop(fixing_issue, files)

    assert_equal files.first(5).join(', '), Issue.last.attention_detail
    assert(files.all? { |f| client.mr_notes.first.last.include?(f) })
  end

  # No abandon, no comment: a row the event cannot leave is not announced.
  def test_nothing_is_posted_when_the_row_cannot_be_given_up
    row = Issue.create!(**base_attrs(4245, 9), status: 'pending')
    client = stop(row, [CONFLICTED])

    assert_equal 'pending', row.reload.status
    assert_empty client.mr_notes
  end

  # A human closed the row during the minutes the resolution lasted (Autodev
  # #97): the stop runs inside `IssueProcessor#process`'s own rescue, so a
  # refused transition escaping it would reach ActiveJob. It does not, the row
  # stays closed, and nothing is posted about a ticket somebody took back.
  def test_a_row_closed_during_the_resolution_stays_closed
    row = pending_issue(mr_iid: 7)
    @on_resolution = -> { Issue.where(id: row.id).update_all(status: 'closed') }
    client = process(row)

    assert_equal 'closed', row.reload.status
    assert_empty client.mr_notes
    refute(client.issue_notes_posted.any? { |n| n.include?(CONFLICTED) })
  end

  private

  def stop(row, files)
    client = StubClient.new
    worker(MrFixer, client).send(:stop_on_rebase_conflict, row,
                                 RebaseConflictError.new(branch: BRANCH, base: TARGET, files: files))
    client
  end

  # --- fixture: `master` and the autodev branch edit the same line ----------

  def build_conflicting_origin
    seed = File.join(@tmpdir, 'seed')
    git(seed, 'init')
    identify(seed)
    git(seed, 'checkout', '-b', TARGET)
    commit(seed, "base\n", 'init')
    git(seed, 'checkout', '-b', BRANCH)
    commit(seed, "autodev-version\n", 'autodev work')
    git(seed, 'checkout', TARGET)
    commit(seed, "target-version\n", 'target moves ahead')
    File.join(@tmpdir, 'origin.git').tap { |bare| git(@tmpdir, 'clone', '--bare', seed, bare) }
  end

  def commit(dir, content, message)
    path = File.join(dir, CONFLICTED)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    git(dir, 'add', CONFLICTED)
    git(dir, 'commit', '-m', message)
  end

  def git(dir, *)
    FileUtils.mkdir_p(dir)
    system('git', *, chdir: dir, out: File::NULL, err: File::NULL)
  end

  def clone_from_bare(work_dir, branch)
    FileUtils.rm_rf(work_dir)
    system('git', 'clone', '--depth', '1', '--branch', branch, @bare, work_dir, out: File::NULL, err: File::NULL)
    identify(work_dir)
  end

  def identify(dir)
    git(dir, 'config', 'user.email', 't@t.com')
    git(dir, 'config', 'user.name', 'Test')
  end

  # --- rows -----------------------------------------------------------------

  def base_attrs(iid, mr_iid)
    { project_path: PROJECT_PATH, issue_iid: iid, mr_iid: mr_iid,
      mr_url: mr_iid && "https://gitlab.example/mr/#{mr_iid}", issue_author_id: 42,
      branch_name: BRANCH, review_count: 1, locale: 'fr', issue_title: 'Parc' }
  end

  def watched_issue
    Issue.create!(**base_attrs(4242, 7), status: 'checking_pipeline').tap do |issue|
      issue.update(checking_pipeline_since: Time.current)
    end
  end

  def fixing_issue = Issue.create!(**base_attrs(4243, 8), status: 'fixing_discussions')
  def pending_issue(mr_iid:) = Issue.create!(**base_attrs(4244, mr_iid), status: 'pending')

  # --- the three units of work, git real, danger-claude and URLs stubbed -----

  def fix(issue)
    client = StubClient.new
    fixer = worker(MrFixer, client)
    fixer.define_singleton_method(:fetch_unresolved_discussions) do |_iid|
      [Discussion.new('t1', [DiscussionNote.new('use Jobs::MissionCreator', nil, '2026-10-09T10:00:00Z')])]
    end
    SkillsInjector.stub(:inject, { all_skills: [] }) { fixer.fix(issue) }
    client
  end

  def poll(issue)
    client = StubClient.new
    mon = worker(PipelineMonitor, client)
    mon.define_singleton_method(:pre_triage) { |_jobs| { verdict: :code, explanation: 'rspec is red' } }
    mon.define_singleton_method(:claude_available?) { true }
    reviews = -> { @reviews += 1 }
    mon.define_singleton_method(:launch_review) { |*| reviews.call }
    SkillsInjector.stub(:inject, { all_skills: [] }) { mon.check(issue) }
    client
  end

  def process(issue)
    client = StubClient.new
    proc_ = worker(IssueProcessor, client)
    stub_reused_branch(proc_)
    proc_.process(issue)
    client
  end

  # The clone, then the real `setup_branch` on the branch the previous run pushed
  # (`reuse`), which is where `resolve_branch` rebases. The implementation that
  # would follow is a counter.
  def stub_reused_branch(proc_)
    bare_clone = method(:clone_from_bare)
    implementations = -> { @implementations += 1 }
    proc_.define_singleton_method(:apply_label_doing) { |*| nil }
    proc_.define_singleton_method(:clone_and_prepare) do |row, iid, work_dir|
      bare_clone.call(work_dir, TARGET)
      setup_branch(row, work_dir, iid, BRANCH, true)
    end
    proc_.define_singleton_method(:run_implementation) { |*| implementations.call }
  end

  def worker(klass, client)
    klass.allocate.tap do |obj|
      obj.send(:init_runner, client: client, config: { 'gitlab_url' => 'https://gitlab.example' },
                             project_config: { 'path' => PROJECT_PATH, 'target_branch' => TARGET },
                             logger: NullLogger.new, token: 'tok')
      %i[log log_error].each { |m| obj.define_singleton_method(m) { |*| nil } }
      obj.define_singleton_method(:apply_label_attention) { |*| nil }
      obj.define_singleton_method(:apply_label_done) { |*| nil }
      stub_git_and_claude(obj)
    end
  end

  # The clone is redirected to the bare repository on disk; the fetch, the
  # `git log` probe, the rebase, `--continue` and the abort run for real.
  def stub_git_and_claude(obj)
    bare_clone = method(:clone_from_bare)
    pushed = @pushed
    prompts = @prompts
    obj.define_singleton_method(:clone_and_checkout) { |dir, branch| bare_clone.call(dir, branch) }
    obj.define_singleton_method(:push_with_lease_fallback) { |_dir, branch, **_o| pushed << branch }
    obj.define_singleton_method(:danger_claude_commit) { |*, **| nil }
    obj.define_singleton_method(:detect_agent) { |*| nil }
    stub_claude(obj, prompts)
  end

  # danger-claude "resolves" nothing; a test may make it crash, or run a human's
  # gesture while it works.
  def stub_claude(obj, prompts)
    hooks = -> { [@claude_error, @on_resolution] }
    obj.define_singleton_method(:danger_claude_prompt) do |_dir, prompt, **_o|
      prompts << prompt
      error, on_resolution = hooks.call
      on_resolution&.call
      raise error if error
    end
  end
end
# rubocop:enable Metrics/ClassLength

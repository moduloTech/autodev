# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'autodev/pipeline_monitor'
require 'autodev/mr_fixer'

# Autodev #91, review round — a target branch that is not there is bounded and it
# is signalled (constat 3).
#
# `MissingTargetBranchError` was made a member of the `ApiUnavailableError` family
# so that every existing boundary would handle it with no new rescue clause, and
# that part was right. What it also inherited was the *waiting*, and a missing
# branch does not resolve itself: it took all four of the pipeline watch's
# guard-rails down at once.
#
#   1. `PipelineMonitor#check` catches the family and logs. Nothing else.
#   2. `abandon_expired_watch` is the last statement of `poll_open_mr`, so the
#      abort never reaches the absolute age bound — deliberately, for an outage.
#   3. the stagnation signature is written *after* `clone_and_fix` returns, so the
#      abort leaves it untouched — again deliberately, for an outage.
#   4. `log_pipeline_poll` collapses, and `supersede!` moves `created_at` forward,
#      so `Issue.without_activity_since` keeps reading the row as fresh and
#      `DormantAudit` never sees it.
#
# Result: a full clone every poll interval, for ever, with no signal to anybody.
# The documentation called that "the line waits"; it is a leak.
#
# The fix does not make it a terminal abandon on a failed read — that is Autodev
# #67's crest line, and it is why `MissingTargetBranchError#confirmed?` exists.
# Only evidence counts: the remote answering that it does not carry the branch, or
# GitLab describing a merge request that names none. "The fetch did not land" and
# "the remote could not be asked" are outages wearing the same exception and keep
# waiting exactly as before.
#
# On evidence, the wait is bounded by `stagnation_threshold` occurrences of the
# *same* missing branch and ends the way Autodev #81 ended the missing review
# skill: a give-up under a reason that names the cause, so the ticket reaches a
# human instead of a log file.
# rubocop:disable Metrics/ClassLength -- the two boundaries are the property, and
# they only read together: half of these lines are the one GitLab stub that lets a
# real `check` and a real `fix` run far enough to reach the rescue under test.
class AMissingBaseIsBoundedAndSignalledTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_PATH = 'modulosource/powerpanne/powerpanne'
  GONE = 'staging-deleted-last-week'

  FakeMr = Struct.new(:iid, :state, :target_branch, :head_pipeline)
  FakePipeline = Struct.new(:id, :status)

  # Answers the poll's own merge-request read (so the poll gets as far as the
  # rebase) and the issue writes the abandon point performs.
  class StubClient
    Note = Struct.new(:id, :body)
    GlIssue = Struct.new(:labels, :id)

    attr_reader :notes, :edits

    def initialize
      @notes = []
      @edits = []
    end

    def merge_request(_path, iid)
      AMissingBaseIsBoundedAndSignalledTest::FakeMr.new(
        iid, 'opened', 'staging', AMissingBaseIsBoundedAndSignalledTest::FakePipeline.new(9, 'failed')
      )
    end

    def pipeline_jobs(_path, _pid, **_opts)
      [{ 'name' => 'rspec', 'stage' => 'test', 'status' => 'failed',
         'allow_failure' => false, 'failure_reason' => 'script_failure' }]
    end

    def merge_request_discussions(_path, _iid, **_opts) = FakePaginated.new([])
    def issue(_path, _iid) = GlIssue.new(labels: ['Doing'], id: 1)
    def issue_notes(_path, _iid, **_opts) = FakePaginated.new([])
    def issue_links(_path, _iid) = []
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
  end

  class FakePaginated
    def initialize(items) = @items = items
    def auto_paginate = @items
    def each(&) = @items.each(&)
  end

  class NullLogger
    %i[info warn error debug].each { |level| define_method(level) { |*, **| nil } }
  end

  def setup = setup_database

  def threshold = 5

  # --- 1. the pipeline watch ------------------------------------------------

  # The first poll behaves exactly as it did: the row is where the previous cycle
  # left it, nothing is rebased, nothing is announced. A single failed
  # establishment of the base may not end a request.
  def test_one_poll_concludes_nothing_and_changes_nothing
    row = watched_issue
    poll(row)

    assert_equal 'checking_pipeline', row.reload.status
    refute row.needs_attention
    assert_nil row.attention_reason
  end

  # And the bound: `stagnation_threshold` polls that all found the same branch
  # gone hand the request back under a reason that names the cause.
  def test_the_wait_is_bounded_by_the_stagnation_threshold # rubocop:disable Minitest/MultipleAssertions
    row = watched_issue
    (threshold - 1).times { poll(row) }

    assert_equal 'checking_pipeline', row.reload.status, 'given up before the threshold'

    poll(row)

    assert_equal 'done', row.reload.status
    assert_equal 'target_branch_missing', row.attention_reason
    assert row.needs_attention
  end

  # Signalled, not only stopped: the three sinks the shared abandon point drives.
  # This is the whole difference with "the line waits" — an operator has to be
  # told which branch, on which request.
  def test_the_give_up_names_the_branch_on_the_ticket
    row = watched_issue
    client = nil
    threshold.times { client = poll(row) }

    assert_includes client.notes.join("\n"), GONE
  end

  def test_the_give_up_hands_the_ticket_back_to_its_author
    row = watched_issue
    client = nil
    threshold.times { client = poll(row) }

    assert_includes client.edits.map { |(_iid, attrs)| attrs[:assignee_ids] }, [42]
  end

  # --- 2. the crest line of Autodev #67 ------------------------------------

  # A base that could not be *established* is an outage wearing this exception:
  # the fetch did not land, or the remote could not be asked. Bounding that would
  # give a healthy request up over a flapping VPN, so it must wait as it always
  # did — however long the outage lasts.
  def test_a_base_that_could_not_be_established_is_never_given_up
    row = watched_issue
    (threshold * 3).times { poll(row, confirmed: false) }

    assert_equal 'checking_pipeline', row.reload.status
    assert_nil row.attention_reason
  end

  # The counter is on the *branch*, not on the poll: a base that changes has not
  # recurred, exactly like a pipeline whose failing job set changes.
  def test_a_different_branch_restarts_the_count
    row = watched_issue
    threshold.times { |n| poll(row, branch: "gone-#{n}") }

    assert_equal 'checking_pipeline', row.reload.status
  end

  # --- 3. the discussion fix, same seam ------------------------------------

  # `MrFixer#fix` rescues the same family for the same reason, and
  # `dispatch_discussions` re-enqueues every `fixing_discussions` row every cycle,
  # so the leak is the same one — clone, fail to establish the base, log, repeat.
  def test_the_discussion_fix_is_bounded_too
    row = fixing_issue
    (threshold - 1).times { fix(row) }

    assert_equal 'fixing_discussions', row.reload.status

    fix(row)

    assert_equal %w[done target_branch_missing], [row.reload.status, row.attention_reason]
  end

  def test_the_discussion_fix_never_gives_up_on_an_unestablished_base
    row = fixing_issue
    (threshold * 3).times { fix(row, confirmed: false) }

    assert_equal 'fixing_discussions', row.reload.status
  end

  private

  def watched_issue
    issue = Issue.create!(project_path: PROJECT_PATH, issue_iid: 4242, mr_iid: 7,
                          mr_url: 'https://gitlab.example/mr/7', issue_author_id: 42,
                          branch_name: 'autodev/issue-4242', status: 'checking_pipeline',
                          review_count: 1, locale: 'fr')
    issue.update(checking_pipeline_since: Time.current)
    issue
  end

  def fixing_issue
    Issue.create!(project_path: PROJECT_PATH, issue_iid: 4243, mr_iid: 8,
                  mr_url: 'https://gitlab.example/mr/8', issue_author_id: 42,
                  branch_name: 'autodev/issue-4243', status: 'fixing_discussions',
                  review_count: 1, locale: 'fr')
  end

  # One poll, with the rebase replaced by the failure the ticket is about. Every
  # step before it is the real code, so the boundary that catches this is the real
  # one.
  def poll(issue, confirmed: true, branch: GONE)
    client = StubClient.new
    mon = worker(PipelineMonitor, client)
    mon.define_singleton_method(:clone_and_checkout) { |dir, _b| FileUtils.mkdir_p(dir) }
    mon.define_singleton_method(:pre_triage) { |_jobs| { verdict: :code, explanation: 'rspec is red' } }
    mon.define_singleton_method(:claude_available?) { true }
    raise_missing_base(mon, confirmed, branch)
    SkillsInjector.stub(:inject, { all_skills: [] }) { mon.check(issue) }
    client
  end

  def fix(issue, confirmed: true, branch: GONE)
    client = StubClient.new
    fixer = worker(MrFixer, client)
    fixer.define_singleton_method(:clone_and_checkout) { |dir, _b| FileUtils.mkdir_p(dir) }
    fixer.define_singleton_method(:fetch_unresolved_discussions) do |_iid|
      [Struct.new(:id, :notes).new('t1', [Struct.new(:body, :position, :created_at)
                                            .new('please fix', nil, '2026-09-01T10:00:00Z')])]
    end
    raise_missing_base(fixer, confirmed, branch)
    SkillsInjector.stub(:inject, { all_skills: [] }) { fixer.fix(issue) }
    client
  end

  def raise_missing_base(worker, confirmed, branch)
    worker.define_singleton_method(:rebase_branch_on_target) do |_dir, _branch, base:|
      _ = base
      raise MissingTargetBranchError.new(branch, confirmed ? 'the remote does not have it' : 'not established',
                                         confirmed: confirmed)
    end
  end

  def worker(klass, client)
    klass.allocate.tap do |obj|
      obj.send(:init_runner, client: client, config: { 'gitlab_url' => 'https://gitlab.example' },
                             project_config: { 'path' => PROJECT_PATH, 'target_branch' => 'master' },
                             logger: NullLogger.new, token: 'tok')
      %i[log log_error].each { |m| obj.define_singleton_method(m) { |*| nil } }
      obj.define_singleton_method(:apply_label_attention) { |*| nil }
      obj.define_singleton_method(:apply_label_done) { |*| nil }
    end
  end
end
# rubocop:enable Metrics/ClassLength

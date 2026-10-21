# frozen_string_literal: true

require_relative 'test_helper'

# Autodev #140 — A#164 / powerpanne/core#16627, 15/10/2026.
#
# Six `:process` jobs were enqueued for one row while it was `pending`; the
# queue was late, so they ran back to back. The first parked the row in
# `needs_clarification`, as it should. The next five each found the row in a
# state `DISPATCHED_FROM[:process]` accepted — it was `PROCESSABLE_STATES`,
# which includes `needs_clarification` since Autodev #75 — so each posed
# `label_doing`, cloned, ran the spec check and posted a new set of questions:
# three different sets in two minutes, then a ticket left on `Doing` that
# `dispatch_new_issues` would never read again.
#
# Real here: `IssueProcessJob#perform` (the staleness guard), `IssueProcessor`
# down to `execute_pipeline`, the state machine and the row. Stubbed: the
# GitLab client (recording every call), the clone and spec check (one
# method, `clone_and_prepare`, standing for both), the activity writer.
module DuplicateProcessJobFixtures
  # Records every call; answers just enough for the processor's first steps
  # (the ticket is open, autodev is user 7) to go through.
  class RecordingClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def issue(*args)
      @calls << [:issue, *args]
      me = Struct.new(:id, :username).new(7, 'autodev')
      Struct.new(:state, :labels, :assignees).new('opened', [], [me])
    end

    def user
      @calls << [:user]
      Struct.new(:id, :username).new(7, 'autodev')
    end

    def method_missing(name, *args, **kwargs)
      @calls << [name, *args, kwargs]
      Struct.new(:id).new(1)
    end

    # Not `true` for everything: `Object#stub` calls a value that answers `call`.
    def respond_to_missing?(name, *) = name != :call
  end

  PROJECT = 'group/project'

  def setup
    setup_database
    @client = RecordingClient.new
    @clones = 0
    @activity = []
    @config = { 'gitlab_url' => 'https://gitlab.example', 'gitlab_token' => 'x',
                'projects' => [{ 'path' => PROJECT }] }
  end

  # Everything a run can touch: the row, GitLab, the clone, the activity journal.
  def snapshot(issue)
    issue.reload
    { status: issue.status, started_at: issue.started_at, calls: @client.calls.size,
      clones: @clones, activity: @activity.dup, events: ActivityEvent.where(issue_id: issue.id).count }
  end

  def run_job(issue, action: :process, processor: nil, &)
    built = processor || lambda { |**kwargs|
      stub_pipeline(IssueProcessor.allocate.tap { |p| p.send(:initialize, **kwargs) }, &)
    }
    with_job_collaborators do
      IssueProcessor.stub(:new, built) do
        IssueProcessJob.new.perform(issue.project_path, issue.issue_iid, action)
      end
    end
  end

  def with_job_collaborators(&)
    Autodev::UsageGate.stub(:available?, true) do
      Config.stub(:load, @config) do
        GitlabHelpers.stub(:build_gitlab_client, ->(*) { @client }, &)
      end
    end
  end

  def processor(logger: StubLogger.new, &)
    stub_pipeline(IssueProcessor.new(client: @client, config: @config, project_config: { 'path' => PROJECT },
                                     logger: logger, token: 'x'), &)
  end

  # `clone_and_prepare` stands for the clone and the spec check: it counts the
  # clone, then lets the test decide where the spec check leaves the row.
  def stub_pipeline(worker, &on_clone)
    test = self
    worker.define_singleton_method(:clone_and_prepare) do |row, *|
      test.instance_variable_set(:@clones, test.instance_variable_get(:@clones) + 1)
      on_clone.call(row)
      'autodev/branch'
    end
    activity = @activity
    worker.define_singleton_method(:log_activity) { |_row, key, **| activity << key }
    worker
  end
end

class ADuplicateProcessJobDoesNothingTest < ActiveSupport::TestCase
  include DatabaseTestHelper
  include DuplicateProcessJobFixtures

  # The production sequence: two jobs queued while the row is `pending`, the
  # first one asks its questions and parks the row.
  test 'the second of two queued :process jobs finds the row parked and does nothing' do
    issue = create_issue(project_path: PROJECT, status: 'pending')
    run_job(issue) { |row| row.clone_complete! && row.spec_unclear! }
    after_first = snapshot(issue)

    assert_equal ['needs_clarification', 1], after_first.values_at(:status, :clones)

    # The job's own guard refuses it: the processor is never even built, so this
    # does not lean on the processor's refusal below.
    run_job(issue, processor: ->(**) { flunk 'the duplicate passed the job guard' })

    assert_equal after_first, snapshot(issue),
                 "the duplicate acted — GitLab calls since: #{@client.calls.drop(after_first[:calls]).inspect}"
  end

  # Defence in depth: the processor itself refuses a row its first transition
  # cannot leave, whoever called it — the job's guard is not the only way in
  # (`PollRouter#enqueue_issue_processing` runs it inline after `reenter!`).
  test 'the processor writes nothing on a row start_processing! cannot leave' do
    issue = create_issue(project_path: PROJECT, status: 'needs_clarification')
    before = snapshot(issue)

    logger = StubLogger.new
    ActivityLogger.stub(:post, ->(*) { flunk 'the refusal wrote an activity entry' }) do
      processor(logger: logger) { |_row| flunk 'the processor must not reach the clone' }.process(issue)
    end

    assert_equal before, snapshot(issue), "GitLab calls: #{@client.calls.inspect}"
    assert_equal [nil, 1], [issue.reload.error_message, logger.messages.grep(/needs_clarification/).size]
  end

  # The row changed under the processor between the job's read and the
  # transition (Autodev #97): `persist_status_change!` raises, and the existing
  # route through `handle_process_error` writes nothing either.
  test 'a row that moved under the processor is left as it is' do
    issue = create_issue(project_path: PROJECT, status: 'pending', retry_count: 1)
    Issue.where(id: issue.id).update_all(status: 'closed')
    before_calls = @client.calls.size

    processor { |_row| flunk 'the processor must not reach the clone' }.process(issue)
    row = Issue.find(issue.id)

    assert_equal({ status: 'closed', started_at: nil, error_message: nil, retry_count: 1,
                   calls: before_calls, clones: 0 },
                 { status: row.status, started_at: row.started_at, error_message: row.error_message,
                   retry_count: row.retry_count, calls: @client.calls.size, clones: @clones })
  end
end

# The other side of the refusal: every legitimate way into the processor — all
# of them from `pending` — still gets a run.
class AProcessJobFromPendingStillRunsTest < ActiveSupport::TestCase
  include DatabaseTestHelper
  include DuplicateProcessJobFixtures

  # The control, so the refusal cannot be "fixed" by never processing at all:
  # from `pending` the same processor poses the working label, assigns itself,
  # announces the start and clones.
  test 'the processor still starts a pending row' do
    issue = create_issue(project_path: PROJECT, status: 'pending')

    processor { |row| row.clone_complete! && row.spec_unclear! }.process(issue)
    written = @client.calls.map(&:first)

    assert_equal({ clones: 1, label_or_assignment: true, note: true, started: true, started_at: true },
                 { clones: @clones, label_or_assignment: written.include?(:edit_issue),
                   note: written.include?(:create_issue_note), started: @activity.include?(:started),
                   started_at: !issue.reload.started_at.nil? })
  end

  # The other half of the production sequence: once the human answers, the poll
  # resumes the row to `pending` and the job it enqueues runs — on a row whose
  # `started_at` the first run already set, which `resume!` does not clear.
  test 'a request resumed after its answer is processed again' do
    issue = create_issue(project_path: PROJECT, status: 'pending')
    run_job(issue) { |row| row.clone_complete! && row.spec_unclear! }
    issue.reload.clarification_received!

    run_job(issue) { |row| row.clone_complete! && row.question_detected! }

    assert_equal [2, 'answering_question'], [@clones, issue.reload.status]
  end

  # The two callers that run the processor without the `:process` guard, both
  # from `pending`, must still get a run.
  test 'a stuck retry still relaunches the processor' do
    issue = create_issue(project_path: PROJECT, status: 'pending')

    run_job(issue, action: :retry_stuck) { |row| row.clone_complete! && row.spec_unclear! }

    assert_equal [1, 'needs_clarification'], [@clones, issue.reload.status]
  end

  test 'a reentry onto reimplementation still starts the processor' do
    issue = create_issue(project_path: PROJECT, status: 'done', started_at: 2.days.ago, finished_at: 1.day.ago)
    issue.reenter!

    processor { |row| row.clone_complete! && row.spec_unclear! }.process(issue)

    assert_equal [1, 'needs_clarification'], [@clones, issue.reload.status]
  end
end

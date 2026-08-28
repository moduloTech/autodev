# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/danger_claude_runner'
require 'autodev/issue_notifier'
require 'autodev/label_manager'
require 'autodev/activity_logger'
require 'autodev/issue_processor'
require 'autodev/poll_router'
require 'stringio'

# Autodev #75, the failure paths.
#
# The clarification flow was built on the nominal path: GitLab answers, the
# budget is intact, the sweep runs to completion. Each of the four cases below is
# a path that only became reachable *because* of #75 — a label write added after
# a state change, a pickup step that now acts instead of merely deciding, a
# backlog drain that did not exist — and each one loses information rather than
# merely failing.
module ClarificationErrorPathFixtures
  FakeGlIssue = Struct.new(:iid, :title, :created_at)
  FakeNote = Struct.new(:system, :created_at, :body)

  Paginated = Struct.new(:items) do
    def auto_paginate = items
  end

  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  # Powerpanne's real configuration: two entry labels in live use by different
  # people (`To do`, `Development::ToDo`).
  PROJECT_CONFIG = {
    'path' => 'group/project',
    'labels_todo' => ['To do', 'Development::ToDo'],
    'label_doing' => 'Development::Doing',
    'label_done' => 'Development::Awaiting Feature Review'
  }.freeze
  CONFIG = { 'gitlab_url' => 'https://gitlab.example', 'gitlab_token' => 'x' }.freeze

  def api_error
    Gitlab::Error::ResponseError.new(
      FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/x'))
    )
  end

  # `edit_issue` can be made to fail the way a 5xx does, or the way a transport
  # failure the gem does not wrap does (`Errno::ECONNRESET` — the case that
  # escapes `manage_labels`' rescue entirely).
  class StubClient
    attr_reader :labels, :edits, :notes

    def initialize(labels: [], edit_error: nil, notes_list: [])
      @labels = labels
      @edit_error = edit_error
      @notes_list = notes_list
      @edits = []
      @notes = []
    end

    def issue(_path, _iid) = Struct.new(:labels, :state).new(@labels, 'opened')

    def issue_notes(_path, _iid, **_opts) = Paginated.new(@notes_list)

    def edit_issue(_path, _iid, **opts)
      @edits << opts
      raise @edit_error if @edit_error

      @labels = opts[:labels].to_s.split(',')
    end

    def create_issue_note(_path, _iid, body)
      @notes << body
      Struct.new(:id).new(1)
    end

    def edit_issue_note(_path, _iid, _note_id, _body) = nil
  end

  def processor(client)
    IssueProcessor.new(client: client, config: CONFIG, project_config: PROJECT_CONFIG,
                       logger: StubLogger.new, token: 'x')
  end
end

# --- 1. a failed pickup edit must not move the ticket to another board column --

class EntryLabelSurvivesAFailedPickupTest < Minitest::Test
  include DatabaseTestHelper
  include ClarificationErrorPathFixtures

  def setup = setup_database

  # `manage_labels` documents its return as "the workflow labels it removed", and
  # `apply_label_doing` feeds it straight to `remember_entry_label`. The rescue
  # ends on `log_error`, whose value is `Logger#error`'s `true`, so the method
  # answers `true` on failure — a lie about its own type, and the next reader's
  # trap.
  def test_a_failed_label_write_answers_with_no_labels_removed
    proc = processor(StubClient.new(labels: ['Development::ToDo'], edit_error: api_error))

    removed = proc.send(:manage_labels, 42, remove: ['Development::ToDo'], add: 'Development::Doing')

    assert_equal [], removed
  end

  # The defect itself, and it is NOT fixed by the line above: `Array(true)` and
  # `Array([])` both intersect `labels_todo` to `[]`, so either way nothing is
  # remembered and `entry_todo_label` falls back to the first of the list.
  #
  # The ticket arrives on `Development::ToDo`, the pickup's `edit_issue` fails on
  # a 5xx so the ticket still carries it, the spec check asks a question — and the
  # fallback strips `Development::ToDo` to pose `To do`, moving the ticket to
  # somebody else's board column. What the code must do instead is look at what
  # the ticket actually carries before falling back to a guess.
  def test_the_entry_label_is_kept_when_the_pickup_edit_failed
    issue = create_issue(status: 'pending')
    client = StubClient.new(labels: ['Development::ToDo', 'PM::Evolution'], edit_error: api_error)
    proc = processor(client)
    proc.send(:start_processing, issue)
    client.instance_variable_set(:@edit_error, nil)

    proc.send(:post_clarification, ['Which company?'], issue.issue_iid, issue)

    assert_includes client.labels, 'Development::ToDo'
    refute_includes client.labels, 'To do'
  end

  # A human who reposes the entry label themselves — powerpanne #16261,
  # 21/07/2026 — is the same shape: nothing was remembered, but the ticket says
  # which column it belongs to.
  def test_the_label_the_ticket_already_carries_wins_over_the_fallback
    issue = create_issue(status: 'pending')
    issue.start_processing!
    issue.clone_complete!
    client = StubClient.new(labels: ['Development::ToDo'])

    processor(client).send(:post_clarification, ['Which company?'], issue.issue_iid, issue)

    assert_equal ['Development::ToDo'], client.labels
    assert_empty client.edits, 'the label is already right: no write, no resource label event'
  end
end

# --- 2. a spent budget must not consume the human's answer -------------------

class SpentBudgetDoesNotConsumeTheAnswerTest < Minitest::Test
  include DatabaseTestHelper
  include ClarificationErrorPathFixtures

  def setup
    setup_database
    @logger = StubLogger.new
  end

  def dispatcher(client)
    Autodev::PollDispatcher.allocate.tap do |d|
      d.instance_variable_set(:@path, PROJECT_CONFIG['path'])
      d.instance_variable_set(:@project_config, PROJECT_CONFIG)
      d.instance_variable_set(:@config, CONFIG)
      d.instance_variable_set(:@logger, @logger)
      d.instance_variable_set(:@token, 'x')
      d.instance_variable_set(:@client, client)
    end
  end

  def answered_client
    StubClient.new(notes_list: [FakeNote.new(system: false, created_at: '2026-07-17T10:13:00Z',
                                             body: 'Voici les précisions demandées.')])
  end

  def spent_request
    create_issue(status: 'needs_clarification', retry_count: 99,
                 clarification_requested_at: Time.parse('2026-07-16T16:00:00Z'))
  end

  def run_pass(issue, client)
    enqueued = []
    IssueProcessJob.stub(:perform_later, ->(*args) { enqueued << args }) do
      dispatcher(client).send(:process_issue, FakeGlIssue.new(issue.issue_iid, 'title', nil))
    end
    enqueued
  end

  # `skip_existing?` *consumes* the clarification — transition, stamp cleared,
  # GitLab note posted — and only then does `exceeded_retries?` on the next line
  # decide the row may not be worked. The dormant audit can re-arm the row, but
  # the human's answer has already been marked as read: `clarification_requested_at`
  # is nil, so the next look finds no question to compare against and reads the
  # row as answered-and-done. The information is gone.
  def test_a_spent_budget_leaves_the_question_unread
    issue = spent_request

    run_pass(issue, answered_client)

    assert_equal 'needs_clarification', issue.reload.status
    refute_nil issue.clarification_requested_at, 'the question must still be on record'
  end

  def test_a_spent_budget_announces_nothing_on_the_ticket
    issue = spent_request
    client = answered_client

    enqueued = run_pass(issue, client)

    assert_empty client.notes, 'nothing may be announced about a resume that did not happen'
    assert_empty enqueued
  end

  # The refusal is not silent: a request stopped by its budget is invisible
  # otherwise — no pass sweeps `needs_clarification`.
  def test_the_refusal_is_logged
    run_pass(spent_request, answered_client)

    assert(@logger.messages.any? { |m| m.include?('retry budget') })
  end

  # The control: under budget, the answer is still picked up.
  def test_a_live_budget_still_picks_the_answer_up
    issue = create_issue(status: 'needs_clarification', retry_count: 0,
                         clarification_requested_at: Time.parse('2026-07-16T16:00:00Z'))

    enqueued = run_pass(issue, answered_client)

    assert_equal 'pending', issue.reload.status
    assert_equal [[PROJECT_CONFIG['path'], issue.issue_iid, :process]], enqueued
  end
end

# --- 3. a label write added after the state change must not fail the request --

class ClarificationLabelWriteIsNotAProcessingFailureTest < Minitest::Test
  include DatabaseTestHelper
  include ClarificationErrorPathFixtures

  def setup = setup_database

  def parked_by(client, issue)
    processor(client).send(:post_clarification, ['Which company?'], issue.issue_iid, issue)
  end

  def spec_checked_issue
    issue = create_issue(status: 'pending')
    issue.start_processing!
    issue.clone_complete!
    issue
  end

  # `apply_label_todo` is the first *raising* GitLab call after `spec_unclear!`
  # has already parked the row. `manage_labels` only rescues
  # `Gitlab::Error::ResponseError`, so a transport failure the gem does not wrap
  # escapes to `IssueProcessor#process`'s `rescue StandardError` →
  # `handle_process_error`. There, `safe_mark_failed!` does nothing at all
  # (`needs_clarification` is not a `mark_failed` source state and
  # `whiny_transitions: false` makes that a silent no-op) while every side effect
  # runs anyway: `retry_count` incremented, `finished_at` and `next_retry_at`
  # stamped, and an error comment posted under the questions. The Autodev #61
  # shape, made reachable by adding a write after the state change.
  #
  # Every other GitLab call in `post_clarification` already swallows its own
  # failure — `notify_issue` rescues, `ActivityLogger.post` rescues so a failed
  # note can never break the state machine. This one has to behave the same.
  def test_a_transport_failure_posing_the_label_does_not_escape
    issue = spec_checked_issue
    client = StubClient.new(labels: ['Development::Doing'], edit_error: Errno::ECONNRESET.new('reset'))

    parked_by(client, issue)

    assert_equal 'needs_clarification', issue.reload.status
  end

  def test_a_transport_failure_posing_the_label_spends_no_retry
    issue = spec_checked_issue
    client = StubClient.new(labels: ['Development::Doing'], edit_error: Errno::ECONNRESET.new('reset'))
    before = issue.retry_count

    parked_by(client, issue)
    issue.reload

    assert_equal before, issue.retry_count
    assert_nil issue.next_retry_at
  end

  # The question stays the last thing the reader sees on the thread.
  def test_a_transport_failure_posing_the_label_posts_no_error_comment
    issue = spec_checked_issue
    client = StubClient.new(labels: ['Development::Doing'], edit_error: Errno::ECONNRESET.new('reset'))

    parked_by(client, issue)

    refute(client.notes.any? { |n| n.include?('ECONNRESET') })
  end

  # A timeout is the other shape of the same failure.
  def test_an_open_timeout_posing_the_label_does_not_escape
    issue = spec_checked_issue
    client = StubClient.new(labels: ['Development::Doing'], edit_error: Net::OpenTimeout.new('timeout'))

    parked_by(client, issue)

    assert_equal 'needs_clarification', issue.reload.status
  end
end

# --- 4. the sweep drains in the order it says it drains in -------------------

class SweepDrainsOldestFirstTest < Minitest::Test
  include DatabaseTestHelper
  include ClarificationErrorPathFixtures

  AUTODEV_USER_ID = 7

  class SweepClient
    def initialize = @noop = nil

    def issue(_path, _iid)
      Struct.new(:labels, :state, :assignees).new([], 'opened', [Struct.new(:id).new(AUTODEV_USER_ID)])
    end

    def issue_notes(_path, _iid, **_opts) = Paginated.new([])
  end

  Paginated = Struct.new(:items) do
    def auto_paginate = items
  end

  def setup
    setup_database
    @out = StringIO.new
  end

  # `parked` declares `order(:clarification_requested_at)` and `run` consumed it
  # with `find_each`, which Rails 8 answers by discarding the scope's order,
  # forcing primary-key order and logging a warning. The report's own comment
  # promises the oldest question drains first — on a partial run that is the
  # order that matters — and it did not happen.
  # Inserted out of order, so primary-key order and chronological order differ.
  def park(days)
    days.each_with_index do |day, i|
      create_issue(project_path: 'group/project', issue_iid: 900 + i,
                   status: 'needs_clarification',
                   clarification_requested_at: Time.parse("#{day}T10:00:00Z"))
    end
  end

  def sweep
    GitlabHelpers.stub(:build_gitlab_client, SweepClient.new) do
      GitlabHelpers.stub(:current_user_id, AUTODEV_USER_ID) do
        Autodev::ClarificationSweep.new(config: CONFIG, apply: false, out: @out).run
      end
    end
    @out.string.scan(/asked (\d{4}-\d{2}-\d{2})/).flatten
  end

  def test_the_report_lists_the_oldest_question_first
    park(%w[2026-07-22 2026-05-15 2026-06-29])

    assert_equal %w[2026-05-15 2026-06-29 2026-07-22], sweep
  end
end

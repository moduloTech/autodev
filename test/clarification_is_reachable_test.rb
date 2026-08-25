# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/danger_claude_runner'
require 'autodev/issue_notifier'
require 'autodev/label_manager'
require 'autodev/activity_logger'
require 'autodev/issue_processor'
require 'autodev/poll_router'

# Autodev #75 — a request parked in `needs_clarification` must be reachable.
#
# `PollDispatcher#process_issue` is the only code that ever asks "has the human
# answered?" (`skip_existing?` → `clarification_received?`), and the only caller
# of `process_issue` is `dispatch_new_issues`, which runs every discovered issue
# through `PollRouter#route` first. `route_by_state` answered `:next` for every
# existing row whose status was not `pending`, so a `needs_clarification` row was
# dropped one step *before* the question was asked — on every project that
# configures the label workflow, which is every real project.
#
# Measured on the 18/08/2026 production copy: 12 rows in `needs_clarification`,
# 3 of them still carrying a todo label and therefore discovered by
# `dispatch_new_issues` every five minutes since 15/05/2026, each with a human
# answer sitting on GitLab. The three `clarification_received` transitions in the
# whole history of the database were all fired by hand from the dashboard
# (`POST /issues/:id/transition`) — none of them carries the
# `activity_clarification_received` entry `requeue_after_clarification` always
# writes, and two of them landed 42 seconds apart on two different tickets.
module ClarificationFixtures
  FakeGlIssue = Struct.new(:iid, :title, :created_at)
  FakeNote = Struct.new(:system, :created_at, :body)

  Paginated = Struct.new(:items) do
    def auto_paginate = items
  end

  PROJECT_CONFIG = {
    'path' => 'group/project',
    'labels_todo' => ['To do'],
    'label_doing' => 'Doing',
    'label_done' => 'Done'
  }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example' }.freeze

  REQUESTED_AT = Time.parse('2026-07-16T16:00:00Z')

  # Only the surface the clarification path touches: the notes read that answers
  # the question, and the activity-note write that announces the resume.
  class StubClient
    attr_reader :created_notes

    def initialize(notes: [])
      @notes = notes
      @created_notes = []
    end

    def issue_notes(_path, _iid, **_opts) = Paginated.new(@notes)

    def create_issue_note(_path, _iid, body)
      @created_notes << body
      Struct.new(:id).new(1)
    end

    def edit_issue_note(_path, _iid, _note_id, _body) = nil
  end

  def human_answer(at: '2026-07-17T10:13:00Z')
    FakeNote.new(system: false, created_at: at, body: 'Voici les précisions demandées : 1. …')
  end

  def waiting_issue(**overrides)
    create_issue(status: 'needs_clarification', clarification_requested_at: REQUESTED_AT, **overrides)
  end
end

# --- 1. the routing step ---------------------------------------------------

class ClarificationRoutingTest < Minitest::Test
  include DatabaseTestHelper
  include ClarificationFixtures

  def setup
    setup_database
    @logger = StubLogger.new
  end

  def router
    PollRouter.new(config: CONFIG, project_config: PROJECT_CONFIG,
                   logger: @logger, token: 'x', pool: nil)
  end

  def test_a_row_waiting_for_clarification_is_handed_to_the_processing_step
    issue = waiting_issue

    verdict = router.route(FakeGlIssue.new(issue.issue_iid, 'title', nil), StubClient.new)

    assert_equal :process, verdict,
                 'the clarification question is asked by process_issue; :next never lets it be asked'
  end

  # The control: every other non-pending state keeps being skipped here.
  def test_an_active_row_is_still_skipped
    issue = create_issue(status: 'checking_pipeline')

    verdict = router.route(FakeGlIssue.new(issue.issue_iid, 'title', nil), StubClient.new)

    assert_equal :next, verdict
  end

  # One declaration of "the states a `:process` cycle may start from", read by
  # the router that lets the row through and by the job that refuses a stale
  # dispatch (Autodev #61). Two lists would be free to disagree, and the
  # disagreement is silent: the row is dropped by whichever is narrower.
  def test_the_router_and_the_job_agree_on_the_processable_states
    assert_equal Issue::PROCESSABLE_STATES, IssueProcessJob::DISPATCHED_FROM[:process]
    assert_includes Issue::PROCESSABLE_STATES, 'needs_clarification'
    assert_includes Issue::PROCESSABLE_STATES, 'pending'
  end
end

# --- 2. the whole pass, from GitLab discovery to the re-armed row ----------

class ClarificationPickupTest < Minitest::Test
  include DatabaseTestHelper
  include ClarificationFixtures

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

  # Runs the real `dispatch_new_issues` with GitLab's discovery query stubbed,
  # so the router step this ticket is about stays in the path under test.
  def run_pass(issue, client)
    enqueued = []
    gl_issue = FakeGlIssue.new(issue.issue_iid, 'title', nil)
    GitlabHelpers.stub(:fetch_assignee_issues, [gl_issue]) do
      GitlabHelpers.stub(:current_user_id, 1) do
        IssueProcessJob.stub(:perform_later, ->(*args) { enqueued << args }) do
          dispatcher(client).send(:dispatch_new_issues)
        end
      end
    end
    enqueued
  end

  def test_a_human_answer_puts_the_request_back_in_the_queue
    issue = waiting_issue
    client = StubClient.new(notes: [human_answer])

    enqueued = run_pass(issue, client)

    assert_equal 'pending', issue.reload.status
    assert_nil issue.clarification_requested_at
    assert_equal [[PROJECT_CONFIG['path'], issue.issue_iid, :process]], enqueued
  end

  # The resume is announced on the ticket's activity journal — which is also how
  # an automatic pickup is told apart from a human clicking the dashboard's
  # transition button.
  def test_the_resume_is_written_to_the_activity_journal
    issue = waiting_issue
    run_pass(issue, StubClient.new(notes: [human_answer]))

    keys = ActivityEvent.where(issue_id: issue.id).map { |e| JSON.parse(e.payload_json)['key'] }

    assert_includes keys, 'clarification_received'
  end

  def test_nobody_answered_leaves_the_request_waiting
    issue = waiting_issue

    enqueued = run_pass(issue, StubClient.new(notes: []))

    assert_equal 'needs_clarification', issue.reload.status
    assert_empty enqueued
  end

  # autodev's own follow-up note on the thread is not an answer to its own
  # question.
  def test_autodevs_own_note_is_not_an_answer
    issue = waiting_issue
    own_note = FakeNote.new(system: false, created_at: '2026-07-17T10:13:00Z',
                            body: ':robot: **autodev** (v1) : traitement en cours')

    run_pass(issue, StubClient.new(notes: [own_note]))

    assert_equal 'needs_clarification', issue.reload.status
  end

  # An answer that predates the question answers a previous round, not this one.
  def test_a_note_older_than_the_question_is_not_an_answer
    issue = waiting_issue

    run_pass(issue, StubClient.new(notes: [human_answer(at: '2026-07-15T09:00:00Z')]))

    assert_equal 'needs_clarification', issue.reload.status
  end
end

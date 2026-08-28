# frozen_string_literal: true

require_relative '../../test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/activity_logger'
require 'stringio'

# Autodev #75 — the arrears.
#
# Making the clarification pickup reachable again (`Issue::PROCESSABLE_STATES`)
# only rescues the requests autodev still *sees*: `dispatch_new_issues` queries
# GitLab for issues carrying a `labels_todo` label, and asking a question does
# not repose one, so 9 of the 12 rows parked on the 18/08/2026 production copy
# sit on `Development::Doing` and are outside that population whatever the router
# answers. A fix that only catches the next question leaves three months of
# client tickets stopped.
#
# This sweep is the *arrears*, and it is the only thing it is — same rule as
# `Autodev::ActivityEventCompaction` (Autodev #53). It reads the DB rather than
# GitLab's label filter, so it does not care which label a ticket carries, and it
# is deliberately a one-shot rake rather than a poll pass: which pass should own
# `needs_clarification` from now on is the open arbitration this ticket hands
# back to the PM, and answering it here would be answering it for her.
# ClassLength: one class per sweep, with the fixtures its two halves share; a
# split would put the dry run and the applied run in different files.
class ClarificationSweepTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  include DatabaseTestHelper

  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example' }.freeze
  REQUESTED_AT = Time.parse('2026-07-16T16:00:00Z')

  FakeNote = Struct.new(:system, :created_at, :body)
  Paginated = Struct.new(:items) do
    def auto_paginate = items
  end

  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  # Notes are keyed by project path so one client can serve a multi-project
  # sweep, which is the shape the production population has.
  FakeGlIssue = Struct.new(:state, :assignees)
  FakeAssignee = Struct.new(:id)

  AUTODEV_USER_ID = 7

  class StubClient
    attr_reader :created_notes

    def initialize(notes_by_path: {}, error_paths: [], gl_issue: nil)
      @notes_by_path = notes_by_path
      @error_paths = error_paths
      @gl_issue = gl_issue
      @created_notes = []
    end

    def issue(_path, _iid) = @gl_issue || FakeGlIssue.new('opened', [FakeAssignee.new(AUTODEV_USER_ID)])

    def issue_notes(path, _iid, **_opts)
      raise Gitlab::Error::ResponseError, response if @error_paths.include?(path)

      Paginated.new(@notes_by_path.fetch(path, []))
    end

    def create_issue_note(path, _iid, _body)
      @created_notes << path
      Struct.new(:id).new(1)
    end

    def edit_issue_note(_path, _iid, _note_id, _body) = nil

    private

    def response = FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/x'))
  end

  def setup
    setup_database
    @out = StringIO.new
    @enqueued = []
  end

  def answer(at: '2026-07-17T10:13:00Z')
    FakeNote.new(system: false, created_at: at, body: 'Voici les précisions demandées.')
  end

  def waiting_issue(path: 'group/project', **overrides)
    create_issue(project_path: path, status: 'needs_clarification',
                 clarification_requested_at: REQUESTED_AT, **overrides)
  end

  def sweep(client, apply: false)
    GitlabHelpers.stub(:build_gitlab_client, client) do
      GitlabHelpers.stub(:current_user_id, AUTODEV_USER_ID) do
        IssueProcessJob.stub(:perform_later, ->(*args) { @enqueued << args }) do
          Autodev::ClarificationSweep.new(config: CONFIG, apply: apply, out: @out).run
        end
      end
    end
  end

  # --- reporting is the default: it writes to GitLab and to the DB ---------

  def test_a_dry_run_changes_nothing
    issue = waiting_issue
    client = StubClient.new(notes_by_path: { 'group/project' => [answer] })

    sweep(client)

    assert_equal 'needs_clarification', issue.reload.status
    assert_empty @enqueued
    assert_empty client.created_notes
  end

  def test_a_dry_run_names_the_answered_requests_and_says_how_to_apply
    issue = waiting_issue

    tally = sweep(StubClient.new(notes_by_path: { 'group/project' => [answer] }))

    assert_equal 1, tally[:answered]
    assert_includes @out.string, "group/project##{issue.issue_iid}"
    assert_includes @out.string, 'APPLY=1'
  end

  # --- APPLY: the row goes back into the queue -----------------------------

  def test_apply_rearms_an_answered_request
    issue = waiting_issue
    client = StubClient.new(notes_by_path: { 'group/project' => [answer] })

    sweep(client, apply: true)

    assert_equal 'pending', issue.reload.status
    assert_nil issue.clarification_requested_at
    assert_equal [['group/project', issue.issue_iid, :process]], @enqueued
  end

  # Same journal entry the poller writes, so a re-armed ticket reads identically
  # whichever path re-armed it.
  def test_apply_announces_the_resume_on_the_ticket
    issue = waiting_issue
    sweep(StubClient.new(notes_by_path: { 'group/project' => [answer] }), apply: true)

    keys = ActivityEvent.where(issue_id: issue.id).map { |e| JSON.parse(e.payload_json)['key'] }

    assert_includes keys, 'clarification_received'
  end

  def test_a_request_nobody_answered_is_left_waiting
    issue = waiting_issue

    tally = sweep(StubClient.new, apply: true)

    assert_equal 'needs_clarification', issue.reload.status
    assert_empty @enqueued
    assert_equal 1, tally[:waiting]
  end

  # --- an unreadable thread is not an answer, and not a "no" either --------

  def test_an_unreadable_comment_history_leaves_the_row_alone
    issue = waiting_issue

    sweep(StubClient.new(error_paths: ['group/project']), apply: true)

    assert_equal 'needs_clarification', issue.reload.status
    assert_empty @enqueued
  end

  # The tally is what a second run is decided on, so the distinction has to
  # survive into it: `waiting` is a verdict, `unreadable` is not.
  def test_an_outage_is_not_counted_as_nobody_answered
    waiting_issue

    tally = sweep(StubClient.new(error_paths: ['group/project']), apply: true)

    assert_equal 1, tally[:unreadable]
    assert_equal 0, tally[:waiting]
  end

  # One unreadable ticket must not take the rest of the arrears down with it.
  def test_one_unreadable_ticket_does_not_stop_the_sweep
    unreadable = waiting_issue(path: 'group/dark')
    answered = waiting_issue(path: 'group/project')
    client = StubClient.new(notes_by_path: { 'group/project' => [answer] },
                            error_paths: ['group/dark'])

    sweep(client, apply: true)

    assert_equal 'needs_clarification', unreadable.reload.status
    assert_equal 'pending', answered.reload.status
  end

  # --- the population is every project, not the one that was investigated --

  def test_every_project_is_swept
    a = waiting_issue(path: 'group/one')
    b = waiting_issue(path: 'group/two')
    client = StubClient.new(notes_by_path: { 'group/one' => [answer], 'group/two' => [answer] })

    sweep(client, apply: true)

    assert_equal 'pending', a.reload.status
    assert_equal 'pending', b.reload.status
  end

  # --- idempotent by construction: a re-armed row leaves the population ----

  def test_a_second_run_finds_nothing
    waiting_issue
    client = StubClient.new(notes_by_path: { 'group/project' => [answer] })
    sweep(client, apply: true)

    tally = sweep(client, apply: true)

    assert_equal 0, tally[:examined]
  end

  # --- the sweep restores the filter it bypasses ---------------------------
  #
  # `dispatch_new_issues` only ever sees a ticket that is open and assigned to
  # autodev, because that is what its GitLab query asks for. Reading the `issues`
  # table instead drops that filter, so the sweep has to ask the question itself
  # — otherwise it re-queues work a human took back, and the next poll cycle's
  # `dispatch_unassignment` closes the row mid-clone. One production row is in
  # exactly that state (PowerPanne #14856, reassigned to a human on 11/06/2026).

  def test_a_ticket_reassigned_to_a_human_is_not_requeued
    issue = waiting_issue
    client = StubClient.new(notes_by_path: { 'group/project' => [answer] },
                            gl_issue: FakeGlIssue.new('opened', [FakeAssignee.new(99)]))

    tally = sweep(client, apply: true)

    assert_equal 'needs_clarification', issue.reload.status
    assert_empty @enqueued
    assert_equal 1, tally[:not_ours]
  end

  def test_a_ticket_closed_on_gitlab_is_not_requeued
    issue = waiting_issue
    client = StubClient.new(notes_by_path: { 'group/project' => [answer] },
                            gl_issue: FakeGlIssue.new('closed', [FakeAssignee.new(AUTODEV_USER_ID)]))

    sweep(client, apply: true)

    assert_equal 'needs_clarification', issue.reload.status
    assert_empty @enqueued
  end

  # An unreadable ticket is not a licence to act on it either.
  def test_a_ticket_whose_state_cannot_be_read_is_left_alone
    issue = waiting_issue
    client = StubClient.new(notes_by_path: { 'group/project' => [answer] })
    client.define_singleton_method(:issue) { |*| raise 'gitlab is down' }

    tally = sweep(client, apply: true)

    assert_equal 'needs_clarification', issue.reload.status
    assert_equal 1, tally[:unreadable]
  end

  # A note that predates the question answered a previous round.
  def test_a_note_older_than_the_question_is_not_an_answer
    issue = waiting_issue
    client = StubClient.new(notes_by_path: { 'group/project' => [answer(at: '2026-07-15T09:00:00Z')] })

    sweep(client, apply: true)

    assert_equal 'needs_clarification', issue.reload.status
  end
end

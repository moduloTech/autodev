# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/danger_claude_runner'
require 'autodev/issue_notifier'
require 'autodev/label_manager'
require 'autodev/activity_logger'
require 'autodev/issue_processor'
require 'autodev/poll_router'

# Autodev #75, direction 1 — asking a question puts the request back on the
# board column the humans read.
#
# `Issue::PROCESSABLE_STATES` made a parked request reachable *once it is
# discovered*, and `dispatch_new_issues` discovers by asking GitLab for the
# issues assigned to autodev **and** carrying a `labels_todo` label.
# `post_clarification` left the ticket on `label_doing`, so the request dropped
# out of that population the moment the question was asked: 9 of the 12 rows
# parked on the 18/08/2026 production copy sit on `Development::Doing`.
#
# The label is also the honest one. While autodev waits for an answer the ticket
# is in the hands of the person who was asked, not in autodev's; showing it as
# work in progress is a lie about the board, and it is the lie that let 12
# requests sleep for up to three months without anybody — autodev or the PM —
# seeing them.
module EntryLabelFixtures
  FakeGlIssue = Struct.new(:iid, :title, :created_at)

  # Only what the label cycle touches: the labels read, the labels written, and
  # the two note endpoints `notify_issue` / `ActivityLogger` reach for.
  class StubClient
    attr_reader :labels, :edits, :notes

    def initialize(labels: [])
      @labels = labels
      @edits = []
      @notes = []
    end

    def issue(_path, _iid) = Struct.new(:labels, :state).new(@labels, 'opened')

    def edit_issue(_path, _iid, **opts)
      @edits << opts
      @labels = opts[:labels].to_s.split(',')
    end

    def create_issue_note(_path, _iid, body)
      @notes << body
      Struct.new(:id).new(1)
    end

    def edit_issue_note(_path, _iid, _note_id, _body) = nil
  end

  # Powerpanne's real configuration: two entry labels actually in use by
  # different people (`To do` by vieira_l / olivei_i, `Development::ToDo` by
  # belpal_j — measured on the resource label events of the parked tickets), one
  # doing label, one done label.
  PROJECT_CONFIG = {
    'path' => 'group/project',
    'labels_todo' => ['To do', 'Development::ToDo'],
    'label_doing' => 'Development::Doing',
    'label_done' => 'Development::Awaiting Feature Review'
  }.freeze
  CONFIG = { 'gitlab_url' => 'https://gitlab.example', 'gitlab_token' => 'x' }.freeze

  def processor(client, project_config: PROJECT_CONFIG)
    IssueProcessor.new(client: client, config: CONFIG, project_config: project_config,
                       logger: StubLogger.new, token: 'x')
  end

  def checking_spec_issue
    issue = create_issue(status: 'pending')
    issue.start_processing!
    issue.clone_complete!
    issue
  end
end

# --- 1. what `post_clarification` poses ------------------------------------

class ClarificationEntryLabelTest < Minitest::Test
  include DatabaseTestHelper
  include EntryLabelFixtures

  def setup = setup_database

  # The whole cycle in one test, because the question is about the *pair*: the
  # entry label autodev stripped on pickup is the one it puts back when it hands
  # the ticket to a human.
  def test_the_entry_label_the_request_arrived_with_is_the_one_reposed
    issue = create_issue(status: 'pending')
    client = StubClient.new(labels: ['Development::ToDo', 'PM::Evolution'])
    proc = processor(client)
    proc.send(:start_processing, issue)

    proc.send(:post_clarification, ['Which company?'], issue.issue_iid, issue)

    assert_includes client.labels, 'Development::ToDo'
    refute_includes client.labels, 'Development::Doing'
  end

  def test_the_other_entry_label_is_reposed_when_that_is_the_one_it_arrived_with
    issue = create_issue(status: 'pending')
    client = StubClient.new(labels: ['To do'])
    proc = processor(client)
    proc.send(:start_processing, issue)

    proc.send(:post_clarification, ['Which company?'], issue.issue_iid, issue)

    assert_includes client.labels, 'To do'
    refute_includes client.labels, 'Development::ToDo'
  end

  # A request that never carried an entry label — it came back through
  # `:retry_stuck`, or a human assigned autodev without touching the board — has
  # no arrival to be faithful to. The project's first declared entry label is the
  # one value autodev can pick without guessing.
  def test_an_unknown_arrival_falls_back_to_the_projects_first_entry_label
    issue = checking_spec_issue
    client = StubClient.new(labels: ['Development::Doing'])

    processor(client).send(:post_clarification, ['Which company?'], issue.issue_iid, issue)

    assert_includes client.labels, 'To do'
  end

  # The invariant the project holds everywhere: one value per GitLab scope. The
  # entry label replaces the doing label, it does not sit beside it.
  def test_the_ticket_never_carries_the_entry_and_the_doing_label_at_once
    issue = checking_spec_issue
    client = StubClient.new(labels: ['Development::Doing', 'Backlog'])

    processor(client).send(:post_clarification, ['Which company?'], issue.issue_iid, issue)

    workflow = client.labels & ['To do', 'Development::ToDo', 'Development::Doing',
                                'Development::Awaiting Feature Review']

    assert_equal 1, workflow.size, "expected exactly one workflow label, got #{workflow.inspect}"
  end

  # Free labels are project taxonomy and none of autodev's business.
  def test_labels_outside_the_workflow_are_left_alone
    issue = checking_spec_issue
    client = StubClient.new(labels: ['Development::Doing', 'Backlog', 'PM::Evolution'])

    processor(client).send(:post_clarification, ['Which company?'], issue.issue_iid, issue)

    assert_includes client.labels, 'Backlog'
    assert_includes client.labels, 'PM::Evolution'
  end

  def test_a_project_without_a_label_workflow_writes_no_label
    issue = checking_spec_issue
    client = StubClient.new(labels: [])

    processor(client, project_config: { 'path' => 'group/project' })
      .send(:post_clarification, ['Which company?'], issue.issue_iid, issue)

    assert_empty client.edits
  end

  # The question is still asked and the row still parks — reposing the label is
  # an addition to `post_clarification`, not a replacement for it.
  def test_the_question_is_still_posted_and_the_row_still_parks
    issue = checking_spec_issue
    client = StubClient.new(labels: ['Development::Doing'])

    processor(client).send(:post_clarification, ['Which company?'], issue.issue_iid, issue)

    assert_equal 'needs_clarification', issue.reload.status
    assert(client.notes.any? { |n| n.include?('Which company?') })
  end
end

# --- 2. idempotence --------------------------------------------------------

class LabelIdempotenceTest < Minitest::Test
  include DatabaseTestHelper
  include EntryLabelFixtures

  def setup = setup_database

  # Posing a label the ticket already carries must not write. A GitLab label edit
  # is not free: it emits a resource label event, and those events are what
  # `LabelHandover#todo_reapplied_after?` and `PollRouter#reenterable?` read to
  # decide whether a human asked for something new.
  def test_reposing_a_label_the_ticket_already_carries_writes_nothing
    issue = checking_spec_issue
    client = StubClient.new(labels: ['To do'])

    processor(client).send(:post_clarification, ['Which company?'], issue.issue_iid, issue)

    assert_empty client.edits
  end

  # Same rule for the label autodev applies far more often.
  def test_applying_the_doing_label_twice_writes_once
    issue = checking_spec_issue
    client = StubClient.new(labels: [])
    proc = processor(client)

    proc.send(:apply_label_doing, issue.issue_iid)
    proc.send(:apply_label_doing, issue.issue_iid)

    assert_equal 1, client.edits.size
  end
end

# --- 3. the cycle closes ---------------------------------------------------

class ClarificationLabelCycleTest < Minitest::Test
  include DatabaseTestHelper
  include EntryLabelFixtures

  def setup = setup_database

  # Ask, wait, get answered, restart: the entry label posed while waiting must be
  # gone once autodev is working again, or the ticket sits in two board columns.
  def test_the_entry_label_is_stripped_again_when_the_request_restarts
    issue = create_issue(status: 'pending')
    client = StubClient.new(labels: ['To do'])
    proc = processor(client)
    proc.send(:start_processing, issue)
    proc.send(:post_clarification, ['Which company?'], issue.issue_iid, issue)

    issue.clarification_received!
    processor(client).send(:start_processing, issue)

    assert_equal ['Development::Doing'], client.labels
  end
end

# --- 4. no other pass changes its mind about these rows --------------------

class ClarificationLabelDoesNotMisrouteTest < Minitest::Test
  include DatabaseTestHelper
  include EntryLabelFixtures

  def setup = setup_database

  # The reposed label puts the row back in `dispatch_new_issues`' population.
  # What must NOT happen there is `handle_reenter`: that branch is for a finished
  # row whose todo label a human reposed, and its `else` is a full
  # re-implementation — clone, danger-claude, push — over a request that has not
  # been answered yet.
  def test_the_reposed_label_routes_to_the_pickup_not_to_a_reimplementation
    issue = create_issue(status: 'needs_clarification', clarification_requested_at: Time.now.utc)
    router = PollRouter.new(config: CONFIG, project_config: PROJECT_CONFIG,
                            logger: StubLogger.new, token: 'x', pool: nil)

    verdict = router.route(FakeGlIssue.new(issue.issue_iid, 'title', nil), StubClient.new)

    assert_equal :process, verdict
    assert_equal 'needs_clarification', issue.reload.status, 'no transition may happen at routing time'
  end

  # The label autodev now poses sits in its *own* workflow scope on the projects
  # that spell their entry label `Development::ToDo`. `LabelHandover` is the one
  # reader that turns "a label moved" into "a human took this back" and closes the
  # row, so it has to answer no — and it does, twice over: `configured_labels`
  # subtracts `labels_todo` from the foreign-scoped set, and `doing_dropped?`
  # refuses to read a missing `label_doing` as a handover while a todo label
  # explains the absence. Pinned here because direction 1 is what makes autodev
  # itself write a label into that scope for the first time.
  def test_the_reposed_entry_label_is_not_read_as_a_human_handover
    handover = Autodev::LabelHandover.new(client: StubClient.new, path: 'group/project',
                                          project_config: PROJECT_CONFIG, logger: StubLogger.new)

    assert_nil handover.verdict(Struct.new(:labels).new(['Development::ToDo', 'Backlog']), 42)
  end

  # The two populations that would act on the row behind the poller's back: the
  # unassignment sweep closes what it selects, and the stalled-state revival
  # rewrites the status with `update_all`. Neither may claim a request that is
  # simply waiting for a human — and the reposed label does not change that,
  # since both select on status, not on labels.
  def test_the_waiting_state_belongs_to_no_sweeping_population
    refute_includes Autodev::PollDispatcher::ACTIVE_STATUSES, 'needs_clarification'
    refute_includes Issue::STALLED_STATES, 'needs_clarification'
  end
end

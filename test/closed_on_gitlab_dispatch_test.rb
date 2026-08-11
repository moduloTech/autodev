# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/activity_logger'

# The active sweep: what `dispatch_unassignment` concludes from one GitLab read
# (Autodev #44, extended by #52).
#
# Until now a GitLab closure was only noticed at the very start of a
# processing run (`IssueProcessor#process`'s early return and the
# `clone_complete!` guard), so a row parked in `checking_pipeline` or
# `fixing_discussions` kept working on a ticket nobody wanted anymore.
#
# The check rides along with `dispatch_unassignment`, which already fetches
# each active row's GitLab issue to test assignment and threw the `state`
# field away — so this costs zero extra API calls. Only active rows are swept
# (decision): a ticket closed while sitting in `pending` or `error` is picked
# up whenever it next moves, not proactively.
#
# #52 adds the third question to the same read: the `labels` array came with the
# payload too and was thrown away just like `state` used to be. A ticket a human
# moved to another workflow label is stopped the same way a closed one is, and
# an unassigned row now ends in `closed` rather than `done`.
class ClosedOnGitlabDispatchTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  include DatabaseTestHelper

  PROJECT_CONFIG = {
    'path' => 'group/project',
    'labels_todo' => ['To Do'],
    'label_doing' => 'Development::Doing',
    'label_done' => 'Development::Awaiting Feature Review'
  }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example' }.freeze
  AUTODEV_ID = 7
  HUMAN_ID = 999
  DOING = 'Development::Doing'
  AWAITING_CR = 'Development::Awaiting CR'

  FakeUser = Struct.new(:id)
  FakeAssignee = Struct.new(:id)
  FakeIssue = Struct.new(:state, :assignees, :labels)
  FakeLabel = Struct.new(:name)
  FakeEvent = Struct.new(:action, :label, :user)
  FakeNote = Struct.new(:id, :body)

  class StubClient
    attr_reader :calls, :event_calls, :notes

    def initialize(state: 'opened', assignee_ids: [AUTODEV_ID], labels: [DOING], events: [])
      @state = state
      @assignee_ids = assignee_ids
      @labels = labels
      @events = events
      @calls = 0
      @event_calls = 0
      @notes = []
    end

    def user = FakeUser.new(AUTODEV_ID)

    def issue(_project, _iid)
      @calls += 1
      FakeIssue.new(@state, @assignee_ids.map { |id| FakeAssignee.new(id) }, @labels)
    end

    def issue_label_events(_project, _iid)
      @event_calls += 1
      @events
    end

    def create_issue_note(_project, _iid, body)
      @notes << body
      FakeNote.new(@notes.size, body)
    end
  end

  def setup
    setup_database
    @logger = StubLogger.new
    GitlabHelpers.instance_variable_set(:@current_user_id, AUTODEV_ID)
  end

  def dispatcher(client)
    Autodev::PollDispatcher.allocate.tap do |d|
      d.instance_variable_set(:@path, PROJECT_CONFIG['path'])
      d.instance_variable_set(:@project_config, PROJECT_CONFIG)
      d.instance_variable_set(:@config, CONFIG)
      d.instance_variable_set(:@logger, @logger)
      d.instance_variable_set(:@client, client)
    end
  end

  def sweep(issue, client)
    dispatcher(client).send(:dispatch_unassignment)
    issue.reload
  end

  # A whole cycle, with the jobs captured instead of enqueued.
  def cycle(client)
    calls = []
    IssueProcessJob.stub(:perform_later, ->(*args) { calls << args.last }) do
      dispatcher(client).send(:dispatch_existing)
    end
    calls
  end

  def active(overrides = {})
    create_issue({ status: 'checking_pipeline', mr_iid: 42 }.merge(overrides))
  end

  # --- closing ------------------------------------------------------

  def test_a_ticket_closed_on_gitlab_is_closed_locally
    issue = sweep(active, StubClient.new(state: 'closed'))

    assert_equal 'closed', issue.status
  end

  def test_closing_stamps_finished_at
    issue = sweep(active, StubClient.new(state: 'closed'))

    refute_nil issue.finished_at
  end

  # A ticket abandoned mid-stagnation shouldn't keep shouting for attention
  # once it's closed — same cleanup the manual close does.
  def test_closing_clears_the_needs_attention_flags
    issue = sweep(active(needs_attention: true, attention_reason: 'stagnation_pipeline'),
                  StubClient.new(state: 'closed'))

    refute issue.needs_attention
    assert_nil issue.attention_reason
  end

  # Closure wins over unassignment: a closed ticket is closed whether or not
  # it is still assigned, and `closed` is the more accurate of the two.
  def test_a_closed_and_unassigned_ticket_is_closed_not_done
    issue = sweep(active, StubClient.new(state: 'closed', assignee_ids: [999]))

    assert_equal 'closed', issue.status
  end

  # --- not closing --------------------------------------------------

  def test_an_open_assigned_ticket_is_left_alone
    issue = sweep(active, StubClient.new)

    assert_equal 'checking_pipeline', issue.status
  end

  # `closed`, not `done` (#52): a ticket a human pulled back mid-implementation
  # was never delivered. The visible consequence is that it leaves
  # `dispatch_done_unassigned`'s population — pinned in
  # test/post_completion_after_unassignment_test.rb.
  def test_an_open_unassigned_ticket_is_closed
    issue = sweep(active, StubClient.new(assignee_ids: [HUMAN_ID]))

    assert_equal 'closed', issue.status
  end

  def test_an_unassigned_ticket_gets_a_gitlab_notice
    client = StubClient.new(assignee_ids: [HUMAN_ID])
    sweep(active, client)

    assert(client.notes.any? { |n| n.include?("j'arrete le travail en cours") })
  end

  # --- the label handover (#15894) -----------------------------------

  # A human removed `Development::Doing` and applied `Development::Awaiting CR`
  # while autodev was watching the pipeline. Autodev polled that MR for two
  # weeks because nothing ever read a label.
  def handover_client(actor_id)
    StubClient.new(labels: [AWAITING_CR, 'PM::Evolution'],
                   events: [FakeEvent.new('add', FakeLabel.new(DOING), FakeUser.new(AUTODEV_ID)),
                            FakeEvent.new('remove', FakeLabel.new(DOING), FakeUser.new(actor_id)),
                            FakeEvent.new('add', FakeLabel.new(AWAITING_CR), FakeUser.new(actor_id))])
  end

  def test_a_ticket_moved_to_another_workflow_label_is_closed
    issue = sweep(active, handover_client(HUMAN_ID))

    assert_equal 'closed', issue.status
  end

  def test_the_handover_is_announced_on_the_ticket
    client = handover_client(HUMAN_ID)
    sweep(active, client)

    assert(client.notes.any? { |n| n.include?(AWAITING_CR) })
  end

  # Autodev applies and removes these labels itself; only somebody else's edit
  # counts.
  def test_the_same_move_made_by_autodev_leaves_the_row_alone
    issue = sweep(active, handover_client(AUTODEV_ID))

    assert_equal 'checking_pipeline', issue.status
  end

  # The objection the naive rule fails: these sit on every ticket, permanently.
  def test_labels_outside_the_workflow_scope_leave_the_row_alone
    issue = sweep(active, StubClient.new(labels: [DOING, 'PM::Evolution', 'Backlog']))

    assert_equal 'checking_pipeline', issue.status
  end

  # Decision: only active rows are swept, so pending/error rows cost nothing.
  def test_a_pending_row_is_not_swept
    client = StubClient.new(state: 'closed')
    issue = sweep(create_issue(status: 'pending'), client)

    assert_equal 'pending', issue.status
    assert_equal 0, client.calls
  end

  def test_an_errored_row_is_not_swept
    client = StubClient.new(state: 'closed')
    issue = sweep(create_issue(status: 'error'), client)

    assert_equal 'error', issue.status
  end

  # --- cost ---------------------------------------------------------

  # The whole point of grafting onto dispatch_unassignment: one read answers
  # all three questions. A second call would mean the refactor missed its goal.
  def test_one_gitlab_read_per_row
    client = StubClient.new(state: 'closed')
    active
    dispatcher(client).send(:dispatch_unassignment)

    assert_equal 1, client.calls
  end

  # The label events are read only once the free label check has a candidate,
  # so a healthy ticket adds nothing to the cycle's API budget (#52). Without
  # this pin the two-stage shape can silently collapse into one call per active
  # row per cycle, forever.
  def test_a_healthy_row_costs_no_label_event_read
    client = StubClient.new
    active
    dispatcher(client).send(:dispatch_unassignment)

    assert_equal 0, client.event_calls
  end

  def test_a_suspicious_row_costs_exactly_one_label_event_read
    client = handover_client(HUMAN_ID)
    active
    dispatcher(client).send(:dispatch_unassignment)

    assert_equal 1, client.event_calls
  end

  # --- resilience ---------------------------------------------------

  # Gitlab::Error::ResponseError's constructor builds its message from the
  # real HTTP response (code, parsed_response, request.base_uri + path); this
  # is the minimum surface it reads. The rescue in check_external_state is
  # narrow, so a plain Gitlab::Error::Error wouldn't exercise it.
  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  class FailingClient < StubClient
    def issue(_project, _iid)
      raise Gitlab::Error::ResponseError,
            FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/issues'))
    end
  end

  def test_a_gitlab_error_leaves_the_row_untouched
    issue = sweep(active, FailingClient.new)

    assert_equal 'checking_pipeline', issue.status
  end

  # --- ordering within one cycle ------------------------------------

  # The sweep only helps if it runs before the row is handed to a worker.
  # `dispatch_pipelines` *enqueues*, and `IssueProcessJob#perform` reloads the
  # row but never checks its status, so Solid Queue picking the job up
  # immediately puts `PipelineMonitor#check` in a race the inline sweep loses
  # almost every time. Losing it costs exactly what #52 exists to prevent: a
  # pipeline resolving on the same cycle as the handover drives the row to
  # `done` through `handle_green`, `done` is not in `ACTIVE_STATUSES` so the
  # sweep never looks at it again, and `apply_label_done` overwrites the
  # workflow label the human just set — GitLab drops `Development::Awaiting CR`
  # to make room for it.
  def test_a_handed_over_row_is_not_dispatched_to_a_worker_in_the_same_cycle
    active

    assert_empty cycle(handover_client(HUMAN_ID))
  end

  # The converse, so the reordering cannot be "fixed" by simply not dispatching.
  def test_an_untouched_row_is_still_dispatched
    active

    assert_equal [:check_pipeline], cycle(StubClient.new)
  end
end

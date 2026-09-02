# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/activity_logger'

# Who still reaches the `post_completion` hook once an unassignment closes the
# row instead of finishing it (Autodev #52).
#
# `dispatch_done_unassigned` selects `done` rows with an open MR that autodev is
# no longer assigned to. Before #52, `stop_unassigned` wrote `done`, so a ticket
# a human pulled back mid-implementation landed in that set and fired the hook
# over a half-finished MR one cycle later. It now writes `closed` and the pass
# no longer sees it — deliberately: the hook is a delivery hook.
#
# The population it exists for is untouched, and that is the half of this file
# that matters most. `finalize_green_done` reaches `done` first and *then* calls
# `hand_ticket_back`, and `dispatch_unassignment` only ever sweeps active rows —
# so a delivered ticket is still `done` and still unassigned when the next cycle
# looks at it.
#
# Since Autodev #60 every *give-up* path does the same (one `abandon` event, one
# reassignment policy), which would have walked all of them into this pass — three
# of them for the first time, since they used to stay assigned to autodev and be
# excluded by accident. So the pass now also filters on `needs_attention: false`:
# no nominal completion sets the flag, every give-up does, and the hook is a
# delivery hook.
class PostCompletionAfterUnassignmentTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_CONFIG = {
    'path' => 'group/project',
    'post_completion' => [%w[bin/deploy]],
    'labels_todo' => ['To Do'],
    'label_doing' => 'Development::Doing',
    'label_done' => 'Development::Awaiting Feature Review'
  }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example' }.freeze
  AUTODEV_ID = 7
  HUMAN_ID = 999

  FakeUser = Struct.new(:id)
  FakeAssignee = Struct.new(:id)
  FakeIssue = Struct.new(:state, :assignees, :labels)
  FakeMr = Struct.new(:state)
  FakeNote = Struct.new(:id, :body)

  class StubClient
    def initialize(assignee_ids:)
      @assignee_ids = assignee_ids
    end

    def user = FakeUser.new(AUTODEV_ID)

    def issue(_project, _iid)
      FakeIssue.new('opened', @assignee_ids.map { |id| FakeAssignee.new(id) },
                    ['Development::Doing'])
    end

    def issue_label_events(_project, _iid) = []
    def merge_request(_project, _iid) = FakeMr.new('opened')
    def create_issue_note(_project, _iid, body) = FakeNote.new(1, body)
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

  # Runs the two passes in the order `dispatch_existing` runs them.
  def sweep_then_hook(client)
    enqueued = []
    IssueProcessJob.stub(:perform_later, ->(*args) { enqueued << args }) do
      dispatcher(client).send(:dispatch_unassignment)
      dispatcher(client).send(:dispatch_done_unassigned)
    end
    enqueued
  end

  def test_a_row_stopped_mid_flight_is_closed
    issue = create_issue(status: 'checking_pipeline', mr_iid: 42)
    sweep_then_hook(StubClient.new(assignee_ids: [HUMAN_ID]))

    assert_equal 'closed', issue.reload.status
  end

  # The documented behaviour change: a deploy hook must not run over work a
  # human interrupted on purpose.
  def test_a_row_stopped_mid_flight_is_not_sent_to_post_completion
    create_issue(status: 'checking_pipeline', mr_iid: 42)

    assert_empty sweep_then_hook(StubClient.new(assignee_ids: [HUMAN_ID]))
  end

  # The guard: this is the population the hook exists for, and it must survive.
  def test_a_delivered_row_still_reaches_post_completion
    issue = create_issue(status: 'done', mr_iid: 42)
    enqueued = sweep_then_hook(StubClient.new(assignee_ids: [HUMAN_ID]))

    assert_equal [[PROJECT_CONFIG['path'], issue.issue_iid, :post_completion]], enqueued
  end

  # ...and it must not be closed on the way there: `dispatch_unassignment` only
  # sweeps active rows, so a `done` row is invisible to it.
  def test_a_delivered_row_is_not_closed_by_the_sweep
    issue = create_issue(status: 'done', mr_iid: 42)
    sweep_then_hook(StubClient.new(assignee_ids: [HUMAN_ID]))

    assert_equal 'done', issue.reload.status
  end

  # An abandoned row is `done` but not delivered, and since Autodev #60 it is also
  # handed back to its author — so it enters this pass's population, where it used
  # to be excluded only by the accident of still being assigned to autodev. The
  # hook is a *delivery* hook (the whole point of #52's `closed`), so an abandoned
  # MR must not be deployed. `needs_attention` is exactly the discriminator: no
  # nominal completion path sets it, and all six give-up paths do — including the
  # one Autodev #66 added, which is the only one that used to reach this pass for
  # real: an MR closed without merging was left unflagged, so a rejected MR was in
  # the deploy population by construction.
  def test_an_abandoned_row_is_not_sent_to_post_completion
    %w[stagnation_pipeline stagnation_discussions pipeline_watch_expired
       review_limit_reached review_failures_exhausted mr_closed_unmerged].each do |reason|
      create_issue(status: 'done', mr_iid: 42, needs_attention: true, attention_reason: reason)
    end

    assert_empty sweep_then_hook(StubClient.new(assignee_ids: [HUMAN_ID]))
  end
end

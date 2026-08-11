# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'

# `Autodev::LabelHandover` — did somebody other than autodev move this ticket on
# with its labels? (Autodev #52)
#
# The production case this exists for: on powerpanne/core #15894, a human removed
# `Development::Doing` and applied `Development::Awaiting CR` on 24/07 at 09:24.
# Autodev never read a label and kept polling that MR's pipeline for two weeks.
#
# Two things make the rule usable on a real project. Tickets there permanently
# carry labels outside the workflow (`PM::Evolution`, `Fourriere`, client names,
# `Backlog`), so "a label autodev does not know" cannot be read literally — the
# verdict is scoped to the GitLab label scope autodev itself lives in. And
# autodev applies and removes these very labels in normal operation, so every
# candidate is confirmed against the resource label events before it counts.
class LabelHandoverTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  AUTODEV_ID = 7
  HUMAN_ID = 999

  # The real powerpanne/core shape (docs/powerpanne-lifecycle.md): `labels_todo`
  # is GitLab's stock unscoped board label, the two labels autodev owns are both
  # in the `Development` scope. Deriving the scope from all three — the shape the
  # ticket first proposed — would disable the rule on this exact project.
  POWERPANNE = {
    'labels_todo' => ['To Do'],
    'label_doing' => 'Development::Doing',
    'label_done' => 'Development::Awaiting Feature Review'
  }.freeze

  # A project whose two autodev-owned labels share no scope: the rule must
  # self-disable down to the two presence checks.
  UNSCOPED = {
    'labels_todo' => ['To Do'],
    'label_doing' => 'In Progress',
    'label_done' => 'Development::Awaiting Feature Review'
  }.freeze

  FakeUser = Struct.new(:id)
  FakeLabel = Struct.new(:name)
  FakeEvent = Struct.new(:action, :label, :user)
  FakeIssue = Struct.new(:labels)

  class StubClient
    attr_reader :event_calls

    def initialize(events: [])
      @events = events
      @event_calls = 0
    end

    def user = FakeUser.new(AUTODEV_ID)

    def issue_label_events(_project, _iid)
      @event_calls += 1
      @events
    end
  end

  # Gitlab::Error::ResponseError builds its message from a real HTTP response;
  # this is the minimum surface its constructor reads. The rescue under test is
  # narrow, so a plain Gitlab::Error::Error would not exercise it.
  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  class FailingClient < StubClient
    def issue_label_events(_project, _iid)
      raise Gitlab::Error::ResponseError,
            FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/issues'))
    end
  end

  def setup
    # `current_user_id` memoizes on the module, so it has to be seeded here.
    GitlabHelpers.instance_variable_set(:@current_user_id, AUTODEV_ID)
    @client = nil
  end

  def ev(action, name, user_id)
    FakeEvent.new(action, FakeLabel.new(name), FakeUser.new(user_id))
  end

  def verdict(labels:, events: [], config: POWERPANNE, client: nil)
    @client = client || StubClient.new(events: events)
    Autodev::LabelHandover.new(client: @client, path: 'group/project',
                               project_config: config, logger: StubLogger.new)
                          .verdict(FakeIssue.new(labels), 42)
  end

  # --- the case this was written for --------------------------------

  def test_a_workflow_label_posed_by_a_human_stops_the_row
    v = verdict(labels: ['Development::Awaiting CR', 'PM::Evolution'],
                events: [ev('add', 'Development::Doing', AUTODEV_ID),
                         ev('remove', 'Development::Doing', HUMAN_ID),
                         ev('add', 'Development::Awaiting CR', HUMAN_ID)])

    assert_equal :workflow_moved, v.reason
  end

  # Naming where the ticket went says more than "doing is gone" — and GitLab
  # drops `Development::Doing` as a side effect of the same edit, so both rules
  # fire and only this one can name the destination.
  def test_the_stop_names_the_label_the_ticket_moved_to
    v = verdict(labels: ['Development::Awaiting CR'],
                events: [ev('add', 'Development::Awaiting CR', HUMAN_ID)])

    assert_equal 'Development::Awaiting CR', v.label
  end

  def test_the_same_move_made_by_autodev_is_not_a_stop
    assert_nil verdict(labels: ['Development::Awaiting CR'],
                       events: [ev('add', 'Development::Awaiting CR', AUTODEV_ID)])
  end

  # --- the done label -----------------------------------------------

  def test_the_done_label_posed_by_a_human_stops_the_row
    v = verdict(labels: ['Development::Awaiting Feature Review'],
                events: [ev('add', 'Development::Awaiting Feature Review', HUMAN_ID)])

    assert_equal :done_added, v.reason
  end

  # The delivery race, and the reason authorship is read rather than inferred:
  # `apply_label_done` writes the GitLab label a few hundred milliseconds before
  # the row's status reaches `done`, from inside the per-issue concurrency lock
  # the poll cycle does not hold. A sweep landing in that gap must not close a
  # ticket autodev is about to deliver.
  def test_the_done_label_applied_by_autodev_is_not_a_stop
    assert_nil verdict(labels: ['Development::Awaiting Feature Review'],
                       events: [ev('add', 'Development::Awaiting Feature Review', AUTODEV_ID)])
  end

  # --- the doing label ----------------------------------------------

  def test_doing_removed_by_a_human_stops_the_row
    v = verdict(labels: ['PM::Evolution'],
                events: [ev('add', 'Development::Doing', AUTODEV_ID),
                         ev('remove', 'Development::Doing', HUMAN_ID)])

    assert_equal :doing_removed, v.reason
  end

  # Autodev removes `label_doing` itself on the needs_clarification path.
  def test_doing_removed_by_autodev_is_not_a_stop
    assert_nil verdict(labels: ['PM::Evolution'],
                       events: [ev('remove', 'Development::Doing', AUTODEV_ID)])
  end

  # --- what must never trigger --------------------------------------

  # The objection the ticket raises against the naive "a label autodev does not
  # know" rule: on powerpanne/core these are on every single ticket, permanently.
  def test_labels_outside_the_workflow_scope_are_ignored
    assert_nil verdict(labels: ['Development::Doing', 'PM::Evolution', 'Fourriere',
                                'Backlog', 'Client Machin'])
  end

  # Re-adding the todo label on an active row is a reentry signal PollRouter
  # owns, never a stop.
  def test_re_adding_the_todo_label_is_not_a_stop
    assert_nil verdict(labels: ['Development::Doing', 'To Do'])
  end

  # --- scope derivation ---------------------------------------------

  # The scope comes from the two labels autodev owns and writes, not from all
  # three: a `labels_todo` sitting in a different scope (or in none, as on
  # powerpanne/core) must not disable the rule.
  def test_the_scope_ignores_labels_todo
    config = POWERPANNE.merge('labels_todo' => ['Board::ToDo'])
    v = verdict(labels: ['Development::Awaiting CR'], config: config,
                events: [ev('add', 'Development::Awaiting CR', HUMAN_ID)])

    assert_equal :workflow_moved, v.reason
  end

  # Self-disabling: no shared scope, no scope rule — and therefore no risk of a
  # false close on a project that does not follow the convention.
  def test_without_a_shared_scope_a_foreign_label_is_ignored
    assert_nil verdict(labels: ['In Progress', 'Development::Awaiting CR'], config: UNSCOPED,
                       events: [ev('add', 'Development::Awaiting CR', HUMAN_ID)])
  end

  # ...but the fallback the ticket prescribes still applies there.
  def test_without_a_shared_scope_a_removed_doing_label_still_stops
    v = verdict(labels: ['Development::Awaiting CR'], config: UNSCOPED,
                events: [ev('remove', 'In Progress', HUMAN_ID)])

    assert_equal :doing_removed, v.reason
  end

  def test_no_label_workflow_configured_is_a_no_op
    assert_nil verdict(labels: ['Development::Awaiting CR'], config: {})
  end

  # --- failing shut --------------------------------------------------
  #
  # A missed handover costs what the bug already costs today. A wrong stop closes
  # a ticket autodev is actively working on and posts a comment blaming somebody
  # who did nothing. Every unknown resolves to "do not stop".

  def test_an_empty_event_list_does_not_stop
    assert_nil verdict(labels: ['Development::Awaiting CR'])
  end

  def test_an_event_for_another_label_does_not_stop
    assert_nil verdict(labels: ['Development::Awaiting CR'],
                       events: [ev('add', 'PM::Evolution', HUMAN_ID)])
  end

  # The labels say `Development::Doing` is gone but its last event is an `add`:
  # the two reads disagree, so the labels are stale and nothing happened.
  def test_a_contradicting_action_does_not_stop
    assert_nil verdict(labels: ['PM::Evolution'],
                       events: [ev('add', 'Development::Doing', HUMAN_ID)])
  end

  def test_a_gitlab_error_does_not_stop
    assert_nil verdict(labels: ['Development::Awaiting CR'], client: FailingClient.new)
  end

  # --- cost ----------------------------------------------------------

  # The whole point of the two-stage shape: stage 1 reads the labels already
  # present in the issue payload `check_external_state` fetches today, so a
  # healthy ticket adds nothing to the poll cycle's API budget.
  def test_a_healthy_ticket_costs_no_extra_api_call
    verdict(labels: ['Development::Doing', 'PM::Evolution'])

    assert_equal 0, @client.event_calls
  end

  def test_a_candidate_costs_exactly_one_api_call
    verdict(labels: ['Development::Awaiting CR'],
            events: [ev('add', 'Development::Awaiting CR', HUMAN_ID)])

    assert_equal 1, @client.event_calls
  end
end

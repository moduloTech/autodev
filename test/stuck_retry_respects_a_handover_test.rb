# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'

# Truthfulness review of the alpha-55 lot. `perform_retry_stuck` relaunched
# `IssueProcessor` without asking whose ticket it was, and `IssueProcessor` asks
# nobody either. The one row that reaches it from a human's hand is a reset:
# `Issue.reset_for_retry!` sends a row with no merge request to `pending` with
# `next_retry_at` stamped, and `dispatch_retries` enqueues `:retry_stuck`.
#
# The door was opened wide by Autodev #86: a parked request whose budget is spent
# shows the budget card whatever GitLab says about the ticket, and that card
# prescribes the reset — on a ticket that may have been reassigned to a human.
# `ResetReclaim` skips every clarification reason, so nothing took the ticket
# back first, and autodev then cloned, implemented and posed its working label
# on work somebody else held.
#
# The retry now asks the three questions `PollDispatcher#check_external_state`
# asks of an active row, in the same order and through the same definition
# (`ExternalState#not_ours?`): closed on GitLab, no longer assigned,
# handed over via the labels.
class StuckRetryRespectsAHandoverTest < Minitest::Test
  include DatabaseTestHelper

  AUTODEV_ID = 7
  HUMAN_ID = 42

  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example' }.freeze
  PROJECT_CONFIG = { 'path' => 'group/project', 'labels_todo' => ['To do'], 'max_retries' => 3,
                     'label_doing' => 'Doing', 'label_done' => 'Done' }.freeze

  FakeGlIssue = Struct.new(:state, :assignees, :labels)
  FakeLabel = Struct.new(:name)
  FakeUser = Struct.new(:id)
  FakeEvent = Struct.new(:label, :action, :user)
  FakeNote = Struct.new(:id)

  class StubClient
    attr_reader :notes, :edits

    def initialize(ticket: nil, raises: nil, events: [])
      @ticket = ticket
      @raises = raises
      @events = events
      @notes = []
      @edits = []
    end

    def issue(_path, _iid)
      raise @raises if @raises

      @ticket
    end

    def issue_label_events(_path, _iid) = Gitlab::PaginatedResponse.new(@events)

    def create_issue_note(_path, _iid, body)
      @notes << body
      FakeNote.new(@notes.size)
    end

    def issue_note(*) = FakeNote.new(1)
    def edit_issue_note(*) = nil

    # Recording, not a no-op (Autodev #126): a handover now hands the ticket to
    # whoever moved the label, and a silent stub would let that edit go wrong
    # unseen.
    def edit_issue(_path, _iid, **attrs)
      @edits << attrs
      nil
    end
  end

  def setup
    setup_database
    @issue = ::Issue.create!(project_path: 'group/project', issue_iid: 1, status: 'pending',
                             next_retry_at: 1.minute.ago, retry_count: 0)
  end

  def ticket(state: 'opened', assignee_ids: [AUTODEV_ID], labels: ['Doing'])
    FakeGlIssue.new(state, assignee_ids.map { |id| FakeUser.new(id) }, labels)
  end

  def test_a_ticket_reassigned_to_a_human_is_not_relaunched
    run_stuck_retry(ticket: ticket(assignee_ids: [HUMAN_ID]))

    assert_equal 'closed', @issue.reload.status
    refute @processed, 'IssueProcessor must not run on a ticket somebody else holds'
  end

  def test_a_ticket_closed_on_gitlab_is_not_relaunched
    run_stuck_retry(ticket: ticket(state: 'closed'))

    assert_equal 'closed', @issue.reload.status
    refute @processed
  end

  # The order is load-bearing (`ExternalState`'s header, Autodev #52): a ticket
  # closed on GitLab is closed whether or not it is still assigned, so it gets
  # the closure entry and never the "no longer assigned" stop notice. Swapping
  # the first two questions left the whole suite green before this test.
  def test_a_closed_ticket_is_read_as_closed_before_being_read_as_reassigned
    client = run_stuck_retry(ticket: ticket(state: 'closed', assignee_ids: [HUMAN_ID]))
    written = client.notes.join("\n")

    assert_includes written, 'cloture sur GitLab'
    refute_includes written, 'Plus assigne'
  end

  def test_a_ticket_handed_over_via_the_labels_is_not_relaunched
    moved = FakeEvent.new(FakeLabel.new('Done'), 'add', FakeUser.new(HUMAN_ID))
    client = run_stuck_retry(ticket: ticket(labels: ['Done']), events: [moved])

    assert_equal 'closed', @issue.reload.status
    refute @processed
    assert_equal [{ assignee_ids: [HUMAN_ID] }], client.edits
  end

  def test_a_ticket_still_ours_is_relaunched_exactly_as_before
    run_stuck_retry(ticket: ticket)

    assert @processed
    assert_nil @issue.reload.next_retry_at
  end

  # A reset parked request carries its reposed entry label (Autodev #75), not
  # `label_doing`: that is somebody asking for work, never a handover.
  def test_a_ticket_carrying_its_entry_label_is_relaunched
    run_stuck_retry(ticket: ticket(labels: ['To do']))

    assert @processed
  end

  # Autodev #67: an unreadable ticket is never permission to take it. The stamp
  # stays, so the next cycle asks again.
  def test_a_read_that_fails_leaves_the_row_for_the_next_cycle
    stamp = @issue.next_retry_at
    run_stuck_retry(raises: Errno::ECONNREFUSED.new)
    @issue.reload

    refute @processed
    assert_equal 'pending', @issue.status
    assert_equal stamp.to_i, @issue.next_retry_at.to_i
  end

  # The path the truthfulness review reproduced, end to end: a parked request
  # over its budget, its ticket reassigned to a human, the watch flags it, an
  # operator presses the reset the budget card prescribes.
  def test_the_reset_the_budget_card_prescribes_does_not_take_a_human_ticket
    parked = ::Issue.create!(project_path: 'group/project', issue_iid: 2, status: 'needs_clarification',
                             retry_count: 4, clarification_requested_at: 1.day.ago)
    human_ticket = ticket(assignee_ids: [HUMAN_ID], labels: ['To do'])
    flag(parked, human_ticket)
    ::Issue.reset_for_retry!(::Issue.where(id: parked.id))

    @issue = parked.reload
    run_stuck_retry(ticket: human_ticket)

    assert_equal 'closed', @issue.reload.status
    refute @processed
  end

  private

  def flag(parked, gl_issue)
    ::GitlabHelpers.stub(:current_user_id, AUTODEV_ID) do
      Autodev::ClarificationWatch.new(client: StubClient.new(ticket: gl_issue), path: 'group/project',
                                      config: CONFIG, project_config: PROJECT_CONFIG,
                                      logger: StubLogger.new, seen_iids: []).run
    end

    assert_equal 'clarification_budget_spent', parked.reload.attention_reason
  end

  def run_stuck_retry(**client_opts)
    @processed = false
    client = StubClient.new(**client_opts)
    job = IssueProcessJob.new.tap { |j| j.define_singleton_method(:log_retry_activity) { |*| nil } }
    job.define_singleton_method(:build_client) { |*| client }

    ::GitlabHelpers.stub(:current_user_id, AUTODEV_ID) do
      ::IssueProcessor.stub(:new, processor_recorder) do
        job.send(:perform_retry_stuck, @issue, CONFIG, PROJECT_CONFIG)
      end
    end
    client
  end

  def processor_recorder
    test = self
    Object.new.tap do |rec|
      rec.define_singleton_method(:process) { |_issue| test.instance_variable_set(:@processed, true) }
    end
  end
end

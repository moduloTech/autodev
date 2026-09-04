# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/activity_logger'

# `Autodev::ExternalState` — what GitLab says about a ticket, and the two writes
# that follow when the answer is "not ours anymore" (Autodev #48).
#
# Both `dispatch_unassignment` and `dispatch_dormant_audit` ask GitLab the same
# question and must reach the same conclusion. #48 exists because that logic
# lived in one pass and the other population was simply never swept; a shared
# module is what keeps the two from drifting again.
class ExternalStateTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  include DatabaseTestHelper

  AUTODEV_ID = 7

  FakeUser = Struct.new(:id)
  FakeAssignee = Struct.new(:id)
  FakeIssue = Struct.new(:state, :assignees)

  PROJECT_CONFIG = {
    'labels_todo' => ['To Do'],
    'label_doing' => 'Development::Doing',
    'label_done' => 'Development::Awaiting Feature Review'
  }.freeze

  FakeNote = Struct.new(:id, :body)

  class StubClient
    attr_reader :notes

    def initialize
      @notes = []
    end

    def user = FakeUser.new(AUTODEV_ID)

    # ActivityLogger.post creates its own note when the issue has no
    # activity_note_id yet; both it and #notify_stop land here, so tests count
    # the ones carrying the stop message rather than the raw total.
    def create_issue_note(_project, _iid, body)
      @notes << body
      FakeNote.new(@notes.size, body)
    end
  end

  class Host
    include Autodev::ExternalState

    def initialize(client, logger)
      @client = client
      @path = 'group/project'
      @project_config = PROJECT_CONFIG
      @logger = logger
    end
  end

  def setup
    setup_database
    GitlabHelpers.instance_variable_set(:@current_user_id, AUTODEV_ID)
    @client = StubClient.new
    @host = Host.new(@client, StubLogger.new)
  end

  def stop_notices
    @client.notes.grep(/j'arrete le travail en cours/)
  end

  def gl(state: 'opened', assignee_ids: [AUTODEV_ID])
    FakeIssue.new(state, assignee_ids.map { |id| FakeAssignee.new(id) })
  end

  # --- reading GitLab's answer --------------------------------------

  def test_a_closed_ticket_reads_as_closed
    assert @host.externally_closed?(gl(state: 'closed'))
  end

  def test_an_open_ticket_does_not
    refute @host.externally_closed?(gl)
  end

  def test_an_assigned_ticket_reads_as_ours
    assert @host.assigned_to_autodev?(gl)
  end

  def test_a_ticket_assigned_to_someone_else_does_not
    refute @host.assigned_to_autodev?(gl(assignee_ids: [999]))
  end

  # --- the writes ---------------------------------------------------

  # `close` is valid from pending and error too, which is what lets the dormant
  # audit reuse this untouched (#48).
  def test_closing_works_from_pending
    issue = create_issue(status: 'pending')
    @host.close_externally(issue)

    assert_equal 'closed', issue.reload.status
  end

  def test_closing_works_from_error
    issue = create_issue(status: 'error')
    @host.close_externally(issue)

    assert_equal 'closed', issue.reload.status
  end

  def test_closing_stamps_finished_at_and_clears_attention
    issue = create_issue(status: 'error', needs_attention: true, attention_reason: 'stagnation_pipeline')
    @host.close_externally(issue)
    issue.reload

    refute_nil issue.finished_at
    refute issue.needs_attention
    assert_nil issue.attention_reason
  end

  # The failure message survives the close: /errors stops listing the row, but
  # /issues/:id still shows why it failed.
  def test_closing_keeps_the_error_message
    issue = create_issue(status: 'error', error_message: 'boom')
    @host.close_externally(issue)

    assert_equal 'boom', issue.reload.error_message
  end

  # `closed`, not `done` (Autodev #52). A ticket a human pulled back was not
  # delivered, and #44 already established that `closed` says more than `done`
  # for the sibling case. The consequence is deliberate: mid-flight stops leave
  # `dispatch_done_unassigned`'s population, so the post_completion hook no
  # longer runs over a half-finished MR.
  def test_stopping_an_unassigned_row_closes_it
    issue = create_issue(status: 'pending')
    @host.stop_unassigned(issue)

    assert_equal 'closed', issue.reload.status
  end

  def test_stopping_an_unassigned_row_stamps_finished_at
    issue = create_issue(status: 'checking_pipeline')
    @host.stop_unassigned(issue)

    refute_nil issue.reload.finished_at
  end

  # Same cleanup the closure does: a ticket a human took back should stop
  # shouting for attention.
  def test_stopping_an_unassigned_row_clears_the_attention_flags
    issue = create_issue(status: 'error', needs_attention: true, attention_reason: 'dormant_exhausted')
    @host.stop_unassigned(issue)
    issue.reload

    refute issue.needs_attention
    assert_nil issue.attention_reason
  end

  # The activity log alone was not enough (#52): it is one line appended to a
  # folded note. The person who unassigned autodev gets an answer on the thread.
  def test_stopping_an_unassigned_row_posts_one_gitlab_notice
    @host.stop_unassigned(create_issue(status: 'implementing'))

    assert_equal 1, stop_notices.size
  end

  def test_the_notice_tells_the_reader_how_to_hand_the_ticket_back
    @host.stop_unassigned(create_issue(status: 'implementing'))

    assert_includes stop_notices.first, 'To Do'
  end

  def test_stopping_an_already_closed_row_is_a_no_op
    issue = create_issue(status: 'closed')
    @host.stop_unassigned(issue)

    assert_empty stop_notices
  end

  # --- posting the stop notice is a write, and stays non-fatal (Autodev #62
  # scopes writes out of the read rule) --------------------------------
  #
  # `notify_stop`'s own rescue named `Gitlab::Error::ResponseError` alone until
  # Autodev #115 widened it to `GitlabHelpers::TRANSPORT_ERRORS`: a peer hanging
  # up mid-response is not an HTTP response, and it used to escape this write
  # uncaught — unlike every other write-swallow in this codebase — and take the
  # whole `stop_unassigned` call down with it, closure included.

  class NoteTransportFailingClient < StubClient
    def create_issue_note(_project, _iid, _body)
      raise Errno::ECONNRESET, 'Connection reset by peer'
    end
  end

  def test_a_transport_error_posting_the_stop_notice_does_not_raise
    logger = StubLogger.new
    host = Host.new(NoteTransportFailingClient.new, logger)

    host.stop_unassigned(create_issue(status: 'pending'))

    assert(logger.messages.any? { |m| m.include?('Failed to post the stop notice') },
           'the swallowed failure must still be logged, not silently dropped')
  end

  def test_a_transport_error_posting_the_stop_notice_still_closes_the_row
    host = Host.new(NoteTransportFailingClient.new, StubLogger.new)
    issue = create_issue(status: 'pending')
    host.stop_unassigned(issue)

    assert_equal 'closed', issue.reload.status
  end

  # --- the label handover -------------------------------------------

  # The #15894 shape: a human replaced `Development::Doing` with
  # `Development::Awaiting CR` while autodev was watching the pipeline.
  def moved_issue(labels)
    FakeLabelledIssue.new('opened', [FakeAssignee.new(AUTODEV_ID)], labels)
  end

  FakeLabelledIssue = Struct.new(:state, :assignees, :labels)

  class HandoverClient < StubClient
    def initialize(events)
      super()
      @events = events
    end

    def issue_label_events(_project, _iid) = @events
  end

  FakeLabel = Struct.new(:name)
  FakeEvent = Struct.new(:action, :label, :user)

  def handover_host(events)
    Host.new(HandoverClient.new(events), StubLogger.new).tap { |h| @client = h.instance_variable_get(:@client) }
  end

  def test_a_ticket_moved_by_a_human_is_closed
    host = handover_host([FakeEvent.new('add', FakeLabel.new('Development::Awaiting CR'),
                                        FakeUser.new(999))])
    issue = create_issue(status: 'checking_pipeline')

    assert host.stop_on_handover(issue, moved_issue(['Development::Awaiting CR']))
    assert_equal 'closed', issue.reload.status
  end

  def test_the_handover_notice_names_the_label
    host = handover_host([FakeEvent.new('add', FakeLabel.new('Development::Awaiting CR'),
                                        FakeUser.new(999))])
    host.stop_on_handover(create_issue(status: 'checking_pipeline'),
                          moved_issue(['Development::Awaiting CR']))

    assert_includes stop_notices.first, 'Development::Awaiting CR'
  end

  def test_a_ticket_autodev_still_holds_is_left_alone
    host = handover_host([])
    issue = create_issue(status: 'checking_pipeline')

    refute host.stop_on_handover(issue, moved_issue(['Development::Doing', 'PM::Evolution']))
    assert_equal 'checking_pipeline', issue.reload.status
  end
end

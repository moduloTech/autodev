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
class ExternalStateTest < Minitest::Test
  include DatabaseTestHelper

  AUTODEV_ID = 7

  FakeUser = Struct.new(:id)
  FakeAssignee = Struct.new(:id)
  FakeIssue = Struct.new(:state, :assignees)

  class StubClient
    def user = FakeUser.new(AUTODEV_ID)
  end

  class Host
    include Autodev::ExternalState

    def initialize(client, logger)
      @client = client
      @path = 'group/project'
      @logger = logger
    end
  end

  def setup
    setup_database
    GitlabHelpers.instance_variable_set(:@current_user_id, AUTODEV_ID)
    @host = Host.new(StubClient.new, StubLogger.new)
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

  def test_stopping_an_unassigned_row_moves_it_to_done
    issue = create_issue(status: 'pending')
    @host.stop_unassigned(issue)
    issue.reload

    assert_equal 'done', issue.status
    refute_nil issue.finished_at
  end
end

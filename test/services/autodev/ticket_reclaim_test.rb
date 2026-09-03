# frozen_string_literal: true

require_relative '../../test_helper'
require 'autodev/gitlab_helpers'

# Autodev #93/#106: the model `ReviewArrearsSweep#reclaim` already exercised in
# production (Autodev #88, corrected by #98), extracted so `PollRouter`'s
# infra recheck and `Autodev::ResetReclaim` can share it instead of each
# re-deriving "does autodev hold this ticket".
class TicketReclaimTest < Minitest::Test
  include DatabaseTestHelper

  AUTODEV_ID = 7
  AUTHOR_ID = 42

  FakeAssignee = Struct.new(:id, :username)
  FakeIssue = Struct.new(:assignees)
  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  # Stateful: a write is visible to the next read, which is what makes the
  # read-back testable at all. Community edition: `assignee_ids` with more
  # than one id is accepted and only the first survives (Autodev #98).
  class StubClient
    attr_reader :edits, :notes

    def initialize(assignee_ids: [AUTHOR_ID], note_error: nil)
      @assignees = assignee_ids.map { |id| FakeAssignee.new(id, "user#{id}") }
      @edits = []
      @notes = []
      @note_error = note_error
    end

    def user = FakeAssignee.new(AUTODEV_ID, 'autodev')
    def issue(_project, _iid) = FakeIssue.new(@assignees.dup)

    def edit_issue(_project, _iid, **opts)
      @edits << opts
      return unless opts.key?(:assignee_ids)

      @assignees = Array(opts[:assignee_ids]).compact.first(1).map { |id| FakeAssignee.new(id, "user#{id}") }
    end

    def create_issue_note(_project, _iid, body)
      if @note_error
        raise Gitlab::Error::ResponseError,
              FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/x'))
      end

      @notes << body
      Struct.new(:id).new(1)
    end
  end

  # Models Community's silent ignore of a write it cannot honour: the edit
  # call succeeds (no exception) but changes nothing.
  class SilentlyIgnoringClient < StubClient
    def edit_issue(_project, _iid, **opts)
      @edits << opts
    end
  end

  def setup
    setup_database
    @logger = StubLogger.new
  end

  def issue(overrides = {})
    create_issue({ project_path: 'group/project', mr_iid: 1 }.merge(overrides))
  end

  def reclaim(client, target, **vars)
    result = nil
    GitlabHelpers.stub(:current_user_id, AUTODEV_ID) do
      result = Autodev::TicketReclaim.new(client: client, logger: @logger)
                                     .reclaim!(target, message_key: :reclaim_operator_reset, **vars)
    end
    result
  end

  def test_returns_nil_and_writes_nothing_when_autodev_already_holds_the_ticket_alone
    client = StubClient.new(assignee_ids: [AUTODEV_ID])

    result = reclaim(client, issue)

    assert_nil result
    assert_empty client.edits
    assert_empty client.notes
  end

  def test_writes_the_assignment
    client = StubClient.new(assignee_ids: [AUTHOR_ID])

    result = reclaim(client, issue)

    assert_equal [AUTODEV_ID], result
    assert_equal [{ assignee_ids: [AUTODEV_ID] }], client.edits
  end

  def test_records_the_displaced_assignee
    client = StubClient.new(assignee_ids: [AUTHOR_ID])
    row = issue

    reclaim(client, row)

    assert_equal AUTHOR_ID, row.reload.displaced_assignee_id
  end

  def test_announces_the_takeover_naming_the_person
    client = StubClient.new(assignee_ids: [AUTHOR_ID])

    reclaim(client, issue)

    assert_equal 1, client.notes.size
    assert_includes client.notes.first, "@user#{AUTHOR_ID}"
  end

  def test_message_key_and_vars_are_interpolated
    client = StubClient.new(assignee_ids: [AUTHOR_ID])

    reclaim(client, issue)

    assert_includes client.notes.first, 'je reprends ce ticket a la demande'
  end

  # A write GitLab accepts (200, no exception) and silently ignores is not a
  # landed reclaim (Autodev #98) — read back rather than assumed.
  def test_raises_when_the_write_is_silently_ignored
    client = SilentlyIgnoringClient.new(assignee_ids: [AUTHOR_ID])

    assert_raises(Autodev::TicketReclaim::AssignmentNotLanded) { reclaim(client, issue) }
  end

  # A failed announcement must not undo the takeover that already landed.
  def test_a_failed_announcement_does_not_undo_the_takeover
    client = StubClient.new(assignee_ids: [AUTHOR_ID], note_error: true)
    row = issue

    result = reclaim(client, row)

    assert_equal [AUTODEV_ID], result
    assert_equal AUTHOR_ID, row.reload.displaced_assignee_id
  end

  def test_no_displaced_assignee_recorded_on_a_previously_unassigned_ticket
    client = StubClient.new(assignee_ids: [])
    row = issue

    reclaim(client, row)

    assert_nil row.reload.displaced_assignee_id
    assert_empty client.notes
  end
end

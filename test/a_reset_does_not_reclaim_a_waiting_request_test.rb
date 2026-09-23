# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/activity_logger'
require 'autodev/poll_router'

# Autodev #86 — `ResetReclaim` reads `needs_attention? && mr_iid` as "autodev
# handed this ticket back when it gave up". A clarification flag means the
# opposite: autodev never gave the ticket away, a human took it, and reclaiming
# it would take it back from them with a comment announcing so. Without the
# flag the reset never reclaimed such a row, so the behaviour is unchanged by #86.
class AResetDoesNotReclaimAWaitingRequestTest < Minitest::Test
  include DatabaseTestHelper

  PATH = 'group/project'
  AUTODEV_ID = 7
  HUMAN_ID = 42
  PROJECT_CONFIG = { 'path' => PATH, 'labels_todo' => ['To do'], 'label_doing' => 'Doing',
                     'label_done' => 'Done', 'label_attention' => 'Attention' }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example',
             'projects' => [PROJECT_CONFIG] }.freeze

  FakeUser = Struct.new(:id, :username)
  FakeIssue = Struct.new(:labels, :assignees)

  # The ticket is held by a human; every write is recorded.
  class StubClient
    attr_reader :edits, :notes

    def initialize
      @edits = []
      @notes = []
      @labels = ['To do']
      @assignees = [FakeUser.new(HUMAN_ID, 'human')]
    end

    def user = FakeUser.new(AUTODEV_ID, 'autodev')
    def issue(_path, _iid) = FakeIssue.new(@labels.dup, @assignees.dup)

    # Stateful, so a reclaim that should not happen lands and reads back rather
    # than failing on its own read-back — the assertion names the defect.
    def edit_issue(_path, _iid, **opts)
      @edits << opts
      @labels = opts[:labels].to_s.split(',') if opts.key?(:labels)
      @assignees = Array(opts[:assignee_ids]).map { |id| FakeUser.new(id, "user#{id}") } if opts.key?(:assignee_ids)
    end

    def create_issue_note(_path, _iid, body)
      @notes << body
      Struct.new(:id).new(1)
    end
  end

  def setup
    setup_database
    @logger = StubLogger.new
  end

  def perform(issue, client)
    GitlabHelpers.stub(:build_gitlab_client, client) do
      GitlabHelpers.stub(:current_user_id, AUTODEV_ID) do
        Autodev::ResetReclaim.perform(issue, config: CONFIG, logger: @logger)
      end
    end
  end

  def test_a_clarification_flag_is_not_a_handback
    issue = create_issue(project_path: PATH, status: 'needs_clarification', mr_iid: 42,
                         needs_attention: true, attention_reason: 'clarification_reassigned')
    client = StubClient.new

    perform(issue, client)

    assert_empty client.edits, 'no update_issue'
    assert_empty client.notes, 'no reclaim note'
  end
end

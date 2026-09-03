# frozen_string_literal: true

require_relative '../../test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/danger_claude_runner'
require 'autodev/issue_notifier'
require 'autodev/label_manager'
require 'autodev/activity_logger'
require 'autodev/issue_processor'
require 'autodev/poll_router'

# Autodev #93/#106, design §6: the GitLab half of an operator's reset, kept
# out of `Issue.reset_for_retry!` itself because that method also serves
# `revive_stalled!` and `recover_on_startup!` — automatic recoveries of a row
# that was never handed back, which must reclaim nothing.
class ResetReclaimTest < Minitest::Test
  include DatabaseTestHelper

  PATH = 'group/project'
  AUTODEV_ID = 7
  AUTHOR_ID = 42

  PROJECT_CONFIG = {
    'path' => PATH, 'labels_todo' => ['To do'], 'label_doing' => 'Doing',
    'label_done' => 'Done', 'label_attention' => 'Attention'
  }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example',
             'projects' => [PROJECT_CONFIG] }.freeze

  FakeAssignee = Struct.new(:id, :username)
  FakeIssue = Struct.new(:labels, :assignees)

  class StubClient
    attr_reader :edits, :notes

    def initialize(assignee_ids: [AUTHOR_ID], labels: [])
      @labels = labels.dup
      @assignees = assignee_ids.map { |id| FakeAssignee.new(id, "user#{id}") }
      @edits = []
      @notes = []
    end

    def user = FakeAssignee.new(AUTODEV_ID, 'autodev')
    def issue(_project, _iid) = FakeIssue.new(@labels.dup, @assignees.dup)

    def edit_issue(_project, _iid, **opts)
      @edits << opts
      @labels = opts[:labels].to_s.split(',') if opts.key?(:labels)
      return unless opts.key?(:assignee_ids)

      @assignees = Array(opts[:assignee_ids]).compact.first(1).map { |id| FakeAssignee.new(id, "user#{id}") }
    end

    def create_issue_note(_project, _iid, body)
      @notes << body
      Struct.new(:id).new(1)
    end

    def assignee_ids = @assignees.map(&:id)
  end

  def setup
    setup_database
    @logger = StubLogger.new
  end

  def abandoned_issue(overrides = {})
    create_issue({ project_path: PATH, status: 'done', mr_iid: 500, needs_attention: true,
                   attention_reason: 'review_failures_exhausted' }.merge(overrides))
  end

  def perform(issue, client)
    GitlabHelpers.stub(:build_gitlab_client, client) do
      GitlabHelpers.stub(:current_user_id, AUTODEV_ID) do
        Autodev::ResetReclaim.perform(issue, config: CONFIG, logger: @logger)
      end
    end
  end

  # -- no-op guards --

  def test_a_plain_error_reset_is_a_no_op
    issue = create_issue(project_path: PATH, status: 'error', mr_iid: nil)
    client = StubClient.new

    perform(issue, client)

    assert_empty client.edits
    assert_empty client.notes
  end

  def test_needs_attention_with_no_mr_yet_is_a_no_op
    issue = abandoned_issue(mr_iid: nil)
    client = StubClient.new

    perform(issue, client)

    assert_empty client.edits
  end

  # -- happy path --

  def test_reclaims_the_assignment
    issue = abandoned_issue
    client = StubClient.new

    perform(issue, client)

    assert_equal [AUTODEV_ID], client.assignee_ids
  end

  def test_reposes_the_working_label_without_clearing_scope
    issue = abandoned_issue
    client = StubClient.new(labels: [PROJECT_CONFIG['label_attention'], 'PM::Evolution'])

    perform(issue, client)

    assert_includes client.issue(PATH, issue.issue_iid).labels, 'Doing'
    assert_includes client.issue(PATH, issue.issue_iid).labels, 'PM::Evolution',
                    'clear_scope must stay off — nobody has asked untouched_since_giveup? on this path'
  end

  def test_announces_the_reclaim_naming_the_operator_request
    issue = abandoned_issue
    client = StubClient.new

    perform(issue, client)

    assert_equal 1, client.notes.size
    assert_includes client.notes.first, 'a la demande'
    assert_includes client.notes.first, "@user#{AUTHOR_ID}"
  end

  # -- refusal (design §6) --

  def test_refuses_when_no_gitlab_client_can_be_built
    issue = abandoned_issue

    error = assert_raises(ConfigError) do
      Autodev::ResetReclaim.perform(issue, config: CONFIG.merge('gitlab_token' => nil), logger: @logger)
    end

    assert_match(/token/i, error.message)
  end

  # -- failure mid-way (design §5) --

  def test_puts_the_label_back_when_the_assignment_does_not_land
    issue = abandoned_issue
    client = StubClient.new
    def client.edit_issue(_project, _iid, **opts)
      @edits << opts
      @labels = opts[:labels].to_s.split(',') if opts.key?(:labels)
      # Model GitLab silently ignoring the assignee write (Autodev #98).
    end

    assert_raises(Autodev::TicketReclaim::AssignmentNotLanded) { perform(issue, client) }

    refute_includes client.issue(PATH, issue.issue_iid).labels, 'Doing',
                    'the label must be put back when the assignment could not be landed'
  end
end

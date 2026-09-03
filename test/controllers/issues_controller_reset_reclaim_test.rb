# frozen_string_literal: true

require_relative '../rails_helper'
require_relative '../stub_logger'
require 'action_dispatch/testing/integration'
require 'devise'
require 'autodev/gitlab_helpers'
require 'autodev/poll_router'

# Regression (design's Testing section, path 2 of 2, Autodev #93/#106):
# powerpanne/core#16030's own sequence, replayed. A request abandoned on
# `review_failures_exhausted` (autodev hands the ticket back to its author,
# per Autodev #60) and then reset from the dashboard must not be found
# unassigned and closed at the next cycle, with a false "autodev was
# unassigned" comment posted on the client's ticket.
class IssuesControllerResetReclaimTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  PATH = 'group/proj'
  AUTODEV_ID = 7
  AUTHOR_ID = 317 # Stephane Meunier's id on 16030

  PROJECT_CONFIG = {
    'path' => PATH, 'labels_todo' => ['To do'], 'label_doing' => 'Development::Doing',
    'label_done' => 'Development::Awaiting Feature Review', 'label_attention' => 'Development::StandBy'
  }.freeze

  FakeAssignee = Struct.new(:id, :username)
  FakeIssue = Struct.new(:labels, :assignees, :state) do
    def initialize(labels, assignees, state = 'opened') = super
  end

  class StubClient
    attr_reader :edits, :notes

    def initialize(assignee_ids:, labels:)
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

  class ExternalStateHost
    include Autodev::ExternalState

    def initialize(client, logger)
      @client = client
      @path = PATH
      @project_config = PROJECT_CONFIG
      @logger = logger
    end
  end

  setup do
    @admin = User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)
    sign_in @admin
    @saved_config = Web.config
    Web.config = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example',
                   'projects' => [PROJECT_CONFIG] }
  end

  teardown do
    Web.config = @saved_config
  end

  # 03:11:15 — abandon under review_failures_exhausted, ticket handed back to
  # the author, `label_attention` posed. 10:20 — reset from the dashboard.
  def abandoned_issue
    Issue.create!(project_path: PATH, issue_iid: rand(10_000..99_999), status: 'done', mr_iid: 16_030,
                  needs_attention: true, attention_reason: 'review_failures_exhausted',
                  issue_author_id: AUTHOR_ID)
  end

  def with_stubbed_client(client, &)
    GitlabHelpers.stub(:build_gitlab_client, client) do
      GitlabHelpers.stub(:current_user_id, AUTODEV_ID, &)
    end
  end

  def test_reset_reclaims_the_assignment
    issue = abandoned_issue
    client = StubClient.new(assignee_ids: [AUTHOR_ID], labels: [PROJECT_CONFIG['label_attention']])

    with_stubbed_client(client) { post "/issues/#{issue.id}/reset" }

    assert_equal [AUTODEV_ID], client.assignee_ids, 'the reclaim did not take the ticket back on GitLab'
    assert_equal AUTHOR_ID, issue.reload.displaced_assignee_id
  end

  def test_reset_transitions_to_checking_pipeline_and_clears_attention
    issue = abandoned_issue
    client = StubClient.new(assignee_ids: [AUTHOR_ID], labels: [PROJECT_CONFIG['label_attention']])

    with_stubbed_client(client) { post "/issues/#{issue.id}/reset" }
    issue.reload

    assert_equal 'checking_pipeline', issue.status
    refute issue.needs_attention
  end

  def test_reset_announces_the_reclaim_naming_the_previous_assignee
    issue = abandoned_issue
    client = StubClient.new(assignee_ids: [AUTHOR_ID], labels: [PROJECT_CONFIG['label_attention']])

    with_stubbed_client(client) { post "/issues/#{issue.id}/reset" }

    assert(client.notes.any? { |n| n.include?("@user#{AUTHOR_ID}") })
  end

  def test_reset_refused_when_no_gitlab_client_can_be_built
    issue = abandoned_issue
    Web.config = Web.config.merge('gitlab_token' => nil)

    post "/issues/#{issue.id}/reset"
    issue.reload

    assert_equal 'done', issue.status, 'a refused reclaim must leave the row untouched — no half-applied reset'
    assert issue.needs_attention
  end

  # The regression itself: replay 16030's next poll cycle against
  # `Autodev::ExternalState` (the same predicates `dispatch_unassignment`
  # uses) and confirm the row is not closed with a false "unassigned" comment.
  # (`test_reset_transitions_to_checking_pipeline_and_clears_attention` above
  # already covers the precondition that the reset itself resumed the row.)
  def test_the_resumed_row_is_not_closed_as_unassigned_at_the_next_cycle
    issue = abandoned_issue
    client = StubClient.new(assignee_ids: [AUTHOR_ID], labels: [PROJECT_CONFIG['label_attention']])
    with_stubbed_client(client) { post "/issues/#{issue.id}/reset" }

    sweep_dispatch_unassignment(issue, client)

    refute_equal 'closed', issue.reload.status
    assert_empty client.notes.grep(/j'arrete le travail en cours/),
                 'a false "unassigned" comment was posted on the client ticket'
  end

  private

  # `PollDispatcher#check_external_state`'s own three questions, replayed
  # directly against `Autodev::ExternalState` so this test does not have to
  # build a whole dispatcher (and its own GitLab client) just to ask them.
  def sweep_dispatch_unassignment(issue, client)
    host = ExternalStateHost.new(client, StubLogger.new)
    gl_issue = client.issue(PATH, issue.issue_iid)
    GitlabHelpers.stub(:current_user_id, AUTODEV_ID) do
      return host.close_externally(issue) if host.externally_closed?(gl_issue)
      return host.stop_unassigned(issue) unless host.assigned_to_autodev?(gl_issue)

      host.stop_on_handover(issue, gl_issue)
    end
  end
end

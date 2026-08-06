# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/activity_logger'

# Closing a ticket on GitLab now closes it on autodev too (Autodev #44).
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
class ClosedOnGitlabDispatchTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_CONFIG = { 'path' => 'group/project' }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example' }.freeze
  AUTODEV_ID = 7

  FakeUser = Struct.new(:id)
  FakeAssignee = Struct.new(:id)
  FakeIssue = Struct.new(:state, :assignees)

  class StubClient
    attr_reader :calls

    def initialize(state: 'opened', assignee_ids: [AUTODEV_ID])
      @state = state
      @assignee_ids = assignee_ids
      @calls = 0
    end

    def user = FakeUser.new(AUTODEV_ID)

    def issue(_project, _iid)
      @calls += 1
      FakeIssue.new(@state, @assignee_ids.map { |id| FakeAssignee.new(id) })
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

  # The pre-existing unassignment behaviour must survive the refactor.
  def test_an_open_unassigned_ticket_still_goes_to_done
    issue = sweep(active, StubClient.new(assignee_ids: [999]))

    assert_equal 'done', issue.status
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
  # both questions. A second call would mean the refactor missed its goal.
  def test_one_gitlab_read_per_row
    client = StubClient.new(state: 'closed')
    active
    dispatcher(client).send(:dispatch_unassignment)

    assert_equal 1, client.calls
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
end

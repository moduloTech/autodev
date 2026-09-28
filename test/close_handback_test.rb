# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'

# Autodev #126 — the dashboard's Clore closes a row whose ticket the bot may
# still hold. `CloseHandback` is the GitLab half: it hands the ticket to
# `Issue#handback_target` when, and only when, the bot is an assignee, and
# reports what happened instead of raising, so the close never depends on it.
class CloseHandbackTest < Minitest::Test
  include DatabaseTestHelper

  PATH = 'group/project'
  AUTODEV_ID = 7
  AUTHOR_ID = 42
  DISPLACED_ID = 55
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example' }.freeze
  LEAKY = 'https://oauth2:glpat-XXXXXXXXXXXXXXXXXXXX@gitlab.example/api/v4 failed'

  FakeUser = Struct.new(:id, :name)
  FakeIssue = Struct.new(:assignees)
  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  # Holds the ticket for `assignee_ids`, records every edit, and can be told
  # to fail its read or its edit.
  class StubClient
    attr_reader :edits
    attr_accessor :issue_error, :edit_error, :edit_response

    def initialize(assignee_ids:)
      @assignees = assignee_ids.map { |id| FakeUser.new(id, "user#{id}") }
      @edits = []
    end

    def user = FakeUser.new(AUTODEV_ID, 'autodev')

    def issue(_path, _iid)
      raise issue_error if issue_error

      FakeIssue.new(@assignees.dup)
    end

    def edit_issue(path, iid, **opts)
      raise edit_error if edit_error

      @edits << [path, iid, opts]
      return edit_response if edit_response

      FakeIssue.new(Array(opts[:assignee_ids]).map { |id| FakeUser.new(id, "Person #{id}") })
    end
  end

  def setup
    setup_database
    @logger = StubLogger.new
    # The memo is module-wide: left set by another test, it would answer the
    # bot id without ever asking this client.
    GitlabHelpers.instance_variable_set(:@current_user_id, nil)
  end

  def row(**overrides)
    create_issue({ project_path: PATH, status: 'closed', issue_author_id: AUTHOR_ID }.merge(overrides))
  end

  def perform(issue, client)
    GitlabHelpers.stub(:build_gitlab_client, client) do
      Autodev::CloseHandback.perform(issue, config: CONFIG, logger: @logger)
    end
  end

  def test_a_ticket_the_bot_holds_is_handed_back_to_its_author
    issue = row
    client = StubClient.new(assignee_ids: [AUTODEV_ID])
    result = perform(issue, client)

    assert_equal :handed_back, result.outcome
    assert_equal AUTHOR_ID, result.target_id
    assert_equal [[PATH, issue.issue_iid, { assignee_ids: [AUTHOR_ID] }]], client.edits
  end

  def test_the_target_name_is_the_assignee_gitlab_returns
    client = StubClient.new(assignee_ids: [AUTODEV_ID])
    client.edit_response = FakeIssue.new([FakeUser.new(AUTHOR_ID, 'Stéphane Meunier')])

    assert_equal 'Stéphane Meunier', perform(row, client).target_name
  end

  def test_the_target_name_falls_back_to_the_id_when_gitlab_names_nobody
    client = StubClient.new(assignee_ids: [AUTODEV_ID])
    client.edit_response = FakeIssue.new([])

    assert_equal AUTHOR_ID.to_s, perform(row, client).target_name
  end

  def test_the_displaced_assignee_wins_over_the_author
    client = StubClient.new(assignee_ids: [AUTODEV_ID])
    result = perform(row(displaced_assignee_id: DISPLACED_ID), client)

    assert_equal :handed_back, result.outcome
    assert_equal [{ assignee_ids: [DISPLACED_ID] }], client.edits.map(&:last)
  end

  def test_a_ticket_a_human_holds_is_left_alone
    client = StubClient.new(assignee_ids: [AUTHOR_ID])
    result = perform(row, client)

    assert_equal :not_held, result.outcome
    assert_empty client.edits
  end

  def test_nobody_to_hand_back_to_writes_nothing
    client = StubClient.new(assignee_ids: [AUTODEV_ID])
    result = perform(row(issue_author_id: nil), client)

    assert_equal :no_target, result.outcome
    assert_empty client.edits, 'an assignee_ids: [nil] edit would unassign the ticket'
  end

  def test_an_unreachable_gitlab_is_a_failed_handback
    [Net::OpenTimeout.new('execution expired'), Errno::ECONNRESET.new,
     ApiUnavailableError.new(:issue, StandardError.new('502'))].each do |error|
      client = StubClient.new(assignee_ids: [AUTODEV_ID])
      client.issue_error = error
      result = perform(row, client)

      assert_equal :failed, result.outcome, "#{error.class} was not read as a failed handback"
      assert_empty client.edits
      refute_nil result.error
    end
  end

  def test_a_refused_edit_is_a_failed_handback
    client = StubClient.new(assignee_ids: [AUTODEV_ID])
    request = FakeRequest.new('https://gitlab.example', '/api/v4/x')
    client.edit_error = Gitlab::Error::ResponseError.new(FakeResponse.new('Forbidden', 403, request))
    result = perform(row, client)

    assert_equal :failed, result.outcome
    assert_equal AUTHOR_ID, result.target_id
  end

  def test_no_client_is_a_failed_handback
    result = Autodev::CloseHandback.perform(row, config: CONFIG.merge('gitlab_token' => nil), logger: @logger)

    assert_equal :failed, result.outcome
    assert_match(/token/i, result.error)
  end

  def test_the_error_is_scrubbed_of_credentials
    client = StubClient.new(assignee_ids: [AUTODEV_ID])
    client.issue_error = Errno::ECONNRESET.new(LEAKY)
    result = perform(row, client)

    assert_equal :failed, result.outcome
    refute_includes result.error, 'glpat-XXXXXXXXXXXXXXXXXXXX'
  end

  def test_a_programming_error_travels_as_itself
    client = StubClient.new(assignee_ids: [AUTODEV_ID])
    client.issue_error = NoMethodError.new("undefined method 'assignees'")

    assert_raises(NoMethodError) { perform(row, client) }
  end
end

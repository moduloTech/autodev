# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'
require 'autodev/gitlab_helpers'

# Autodev #126 — Clore hands the ticket back when the bot holds it. The row is
# closed whatever GitLab answers (the off-switch is always available); the
# handback's outcome is audited and told in a flash.
class IssuesControllerCloseHandbackTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  PATH = 'group/proj'
  AUTODEV_ID = 7
  AUTHOR_ID = 42
  RETURN_TO = '/issues?tab=delivered_review'

  RESULTS = {
    handed_back: Autodev::CloseHandback::Result.new(:handed_back, AUTHOR_ID, 'Stéphane Meunier', nil),
    not_held: Autodev::CloseHandback::Result.new(:not_held, nil, nil, nil),
    no_target: Autodev::CloseHandback::Result.new(:no_target, nil, nil, nil),
    failed: Autodev::CloseHandback::Result.new(:failed, AUTHOR_ID, nil, 'execution expired')
  }.freeze

  FakeUser = Struct.new(:id, :name)
  FakeIssue = Struct.new(:assignees)

  # The bot holds the ticket, and its read fails with a token in the message.
  class LeakyClient
    def user = FakeUser.new(AUTODEV_ID, 'autodev')
    def issue(*) = raise(Errno::ECONNRESET, 'https://oauth2:glpat-XXXXXXXXXXXXXXXXXXXX@gitlab.example failed')
  end

  setup do
    @project = Project.create!(gitlab_path: PATH, slug: 'group__proj')
    @member = User.create!(email: 'member@modulotech.fr', name: 'Member')
    ProjectMembership.create!(user: @member, project: @project, role: 'contributor')
    sign_in @member
    @issue = Issue.create!(project_path: PATH, issue_iid: 600, status: 'done', issue_author_id: AUTHOR_ID,
                           needs_attention: true, attention_reason: 'stagnation_pipeline')
    @saved_config = Web.config
    Web.config = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example' }
    GitlabHelpers.instance_variable_set(:@current_user_id, nil)
  end

  teardown do
    Web.config = @saved_config
  end

  def close_with(result, &observe)
    handback = lambda do |issue, config:, logger:|
      observe&.call(issue, config, logger)
      result
    end
    Autodev::CloseHandback.stub(:perform, handback) do
      post "/issues/#{@issue.id}/close", params: { return_to: RETURN_TO }
    end
  end

  def assert_one_handback_log(outcome, result)
    logs = AuditLog.where(action: 'issue.close_handback', resource_id: @issue.id).to_a

    assert_equal 1, logs.size, "#{outcome}: expected exactly one issue.close_handback row"
    assert_equal @member.id, logs.first.actor_id
    assert_equal({ 'project_path' => PATH, 'iid' => 600, 'outcome' => outcome.to_s,
                   'target_id' => result.target_id }, logs.first.payload)
  end

  def test_the_handback_runs_on_a_row_already_closed
    seen = {}
    close_with(RESULTS[:handed_back]) { |issue, config, _| seen = { status: issue.reload.status, config: config } }

    assert_equal 'closed', seen[:status], 'the handback must run after the close, never instead of it'
    assert_equal 'https://gitlab.example', seen[:config]['gitlab_url']
  end

  def test_every_outcome_closes_the_row
    RESULTS.each do |outcome, result|
      @issue.update_columns(status: 'done', finished_at: nil)
      close_with(result)
      @issue.reload

      assert_equal 'closed', @issue.status, "a #{outcome} handback left the row open"
      refute_nil @issue.finished_at, "a #{outcome} handback left finished_at empty"
    end
  end

  def test_every_outcome_is_audited_once_with_its_payload
    RESULTS.each do |outcome, result|
      AuditLog.where(action: 'issue.close_handback').delete_all
      @issue.update_columns(status: 'done')
      close_with(result)

      assert_one_handback_log(outcome, result)
    end
  end

  def test_a_handed_back_ticket_is_told_as_a_notice
    close_with(RESULTS[:handed_back])

    assert_includes flash[:notice].to_s, 'Stéphane Meunier'
    assert_nil flash[:alert]
    assert_redirected_to RETURN_TO
  end

  def test_a_failed_handback_is_told_as_an_alert
    close_with(RESULTS[:failed])

    assert_includes flash[:alert].to_s, 'execution expired'
    assert_nil flash[:notice]
    assert_redirected_to RETURN_TO
  end

  def test_nobody_to_hand_back_to_is_told_as_an_alert
    close_with(RESULTS[:no_target])

    refute_nil flash[:alert]
    assert_nil flash[:notice]
    assert_redirected_to RETURN_TO
  end

  def test_a_ticket_the_bot_did_not_hold_says_nothing
    close_with(RESULTS[:not_held])

    assert_nil flash[:notice]
    assert_nil flash[:alert]
    assert_redirected_to RETURN_TO
  end

  # Unstubbed service: a real transport failure whose message carries a PAT.
  def test_a_failure_message_reaches_the_flash_scrubbed
    GitlabHelpers.stub(:build_gitlab_client, LeakyClient.new) do
      post "/issues/#{@issue.id}/close"
    end

    assert_equal 'closed', @issue.reload.status
    refute_nil flash[:alert]
    refute_includes flash[:alert], 'glpat-XXXXXXXXXXXXXXXXXXXX'
  end
end

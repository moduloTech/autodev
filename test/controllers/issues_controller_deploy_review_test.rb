# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# The review-env redeploy action: GET renders the lazy turbo-frame (availability
# probe), POST (re)triggers the deploy_review job, flashes the result, and
# records an audit row. The Autodev::DeployReview service is stubbed so the
# tests are deterministic and never reach GitLab (its own behaviour is covered
# in test/services/autodev/deploy_review_test.rb).
class IssuesControllerDeployReviewTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  Outcome = Autodev::DeployReview::Outcome

  # Canned stand-in for the service: returns the same outcome from both entry
  # points (a test only exercises one per request).
  class FakeService
    def initialize(outcome)
      @outcome = outcome
    end

    def availability
      @outcome
    end

    def trigger!
      @outcome
    end
  end

  setup do
    # Admin so the issue is visible (issues_dataset scopes non-admins to their
    # project memberships); the action itself has no permission gate.
    @user = User.create!(email: 'dev@modulotech.fr', name: 'Dev', admin: true)
    @issue = Issue.create!(project_path: 'group/proj', issue_iid: 700,
                           status: 'checking_pipeline', branch_name: 'autodev/issue-700')
    sign_in @user
  end

  def with_outcome(outcome, &)
    Autodev::DeployReview.stub(:new, FakeService.new(outcome), &)
  end

  def test_get_renders_the_frame_with_an_enabled_button_when_available
    with_outcome(Outcome.new(state: :available)) do
      get "/issues/#{@issue.id}/deploy_review"
    end

    assert_response :success
    assert_match(/<turbo-frame[^>]*id="deploy-review-#{@issue.id}"/, response.body)
    assert_match %r{action="/issues/#{@issue.id}/deploy_review"}, response.body
  end

  def test_get_renders_a_disabled_button_with_reason_when_no_job
    with_outcome(Outcome.new(state: :no_job)) do
      get "/issues/#{@issue.id}/deploy_review"
    end

    assert_match(/disabled/, response.body)
    refute_match %r{<form[^>]*action="/issues/#{@issue.id}/deploy_review"}, response.body
  end

  def test_get_blocked_renders_disabled_with_upstream_reason
    with_outcome(Outcome.new(state: :blocked)) do
      get "/issues/#{@issue.id}/deploy_review"
    end

    assert_match(/disabled/, response.body)
    assert_match(/amont/, response.body)
  end

  def test_get_unknown_issue_not_found
    get '/issues/999999/deploy_review'

    assert_response :not_found
  end

  def test_post_triggers_flashes_notice_and_records_audit
    assert_difference -> { AuditLog.where(action: 'issue.deploy_review').count }, 1 do
      with_outcome(Outcome.new(state: :triggered, action: :play)) do
        post "/issues/#{@issue.id}/deploy_review"
      end
    end

    assert_redirected_to "/issues/#{@issue.id}"
    assert_predicate flash[:notice], :present?
  end

  def test_post_retry_uses_the_retried_message
    with_outcome(Outcome.new(state: :triggered, action: :retry)) do
      post "/issues/#{@issue.id}/deploy_review"
    end

    assert_redirected_to "/issues/#{@issue.id}"
    assert_predicate flash[:notice], :present?
  end

  def test_post_unavailable_flashes_alert_and_records_no_audit
    assert_no_difference -> { AuditLog.where(action: 'issue.deploy_review').count } do
      with_outcome(Outcome.new(state: :no_job)) do
        post "/issues/#{@issue.id}/deploy_review"
      end
    end

    assert_redirected_to "/issues/#{@issue.id}"
    assert_predicate flash[:alert], :present?
  end

  def test_post_error_flashes_sanitized_alert_without_raw_message
    with_outcome(Outcome.new(state: :error,
                             message: 'Server responded with 500 at https://gitlab/api/v4/jobs/42/retry')) do
      post "/issues/#{@issue.id}/deploy_review"
    end

    assert_redirected_to "/issues/#{@issue.id}"
    assert_predicate flash[:alert], :present?
    refute_match(%r{gitlab/api}, flash[:alert]) # raw GitLab error must not leak to the user
  end
end

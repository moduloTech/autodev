# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# Deploy-review surface for merge requests autodev never tracked (task #43):
# a project selector + open-MR list (`#index`), a lazy availability probe
# (`#availability`), and a trigger action (`#trigger`) — all reusing
# Autodev::DeployReview via its Target value object instead of an Issue row.
# GitLab (both the MR list and the DeployReview service) is stubbed so the
# suite never touches the network; DeployReview's own behavior is covered in
# test/services/autodev/deploy_review_test.rb.
class DeployReviewsControllerTest < ActionDispatch::IntegrationTest # rubocop:disable Metrics/ClassLength
  include Devise::Test::IntegrationHelpers

  Outcome = Autodev::DeployReview::Outcome
  MergeRequest = Struct.new(:iid, :title, :source_branch, :author, :state)
  Author = Struct.new(:name)

  # Canned stand-in for Autodev::DeployReview — same pattern as
  # IssuesControllerDeployReviewTest's FakeService.
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

  # Fake GitLab client — only the methods this controller calls. The MR list
  # answers a paginated stand-in because the search auto-paginates it
  # (Autodev #45: one capped page hid 29 of 129 open MRs in prod).
  class FakePaginated
    def initialize(rows) = @rows = rows
    def auto_paginate = @rows
  end

  class FakeClient
    def initialize(merge_requests: [], related: {}, raise_on_list: false)
      @merge_requests = merge_requests
      @related = related
      @raise_on_list = raise_on_list
    end

    def merge_requests(_project_path, _opts = {})
      raise StandardError, 'boom' if @raise_on_list

      FakePaginated.new(@merge_requests)
    end

    def related_merge_requests(_project_path, issue_iid) = @related.fetch(issue_iid, [])
  end

  setup do
    @user = User.create!(email: 'dev@modulotech.fr', name: 'Dev')
    @other_user = User.create!(email: 'other@modulotech.fr', name: 'Other')
    @project = Project.create!(gitlab_path: 'group/proj', slug: 'group__proj')
    @other_project = Project.create!(gitlab_path: 'group/other', slug: 'group__other')
    ProjectMembership.create!(user: @user, project: @project, role: 'contributor')
    sign_in @user
  end

  def with_client(client, &)
    GitlabHelpers.stub(:build_gitlab_client, client, &)
  end

  def with_outcome(outcome, &)
    Autodev::DeployReview.stub(:new, FakeService.new(outcome), &)
  end

  # === #index ==============================================================

  def test_index_renders_just_the_selector_without_a_project_param
    get '/deploy_review'

    assert_response :success
    assert_match(/<select[^>]*name="project"/, response.body)
    refute_match(/deploy-review-mr-/, response.body)
  end

  def test_index_lists_open_mrs_for_a_visible_selected_project # rubocop:disable Minitest/MultipleAssertions
    mrs = [MergeRequest.new(iid: 5, title: 'Fix thing', source_branch: 'fix-thing',
                            author: Author.new(name: 'Alice'))]

    with_client(FakeClient.new(merge_requests: mrs)) do
      get '/deploy_review', params: { project: 'group/proj' }
    end

    assert_response :success
    assert_match(/Fix thing/, response.body)
    assert_match(/fix-thing/, response.body)
    assert_match(/Alice/, response.body)
  end

  def test_index_annotates_an_already_tracked_mr_with_a_badge
    Issue.create!(project_path: 'group/proj', issue_iid: 900, mr_iid: 5,
                  status: 'done', branch_name: 'fix-thing')
    mrs = [MergeRequest.new(iid: 5, title: 'Fix thing', source_branch: 'fix-thing',
                            author: Author.new(name: 'Alice'))]

    with_client(FakeClient.new(merge_requests: mrs)) do
      get '/deploy_review', params: { project: 'group/proj' }
    end

    assert_match(/suivi/i, response.body)
  end

  def test_index_falls_back_to_the_selector_for_a_project_the_user_cannot_see
    get '/deploy_review', params: { project: 'group/other' }

    assert_response :success
    refute_match(/deploy-review-mr-/, response.body)
  end

  def test_index_surfaces_an_error_state_on_gitlab_failure
    with_client(FakeClient.new(raise_on_list: true)) do
      get '/deploy_review', params: { project: 'group/proj' }
    end

    assert_response :success
  end

  # === #index search (Autodev #45) =========================================
  #
  # A CSM arrives with a ticket number off a "Ready for QA" board, not an MR
  # number, and the list runs to 100+ rows. Without a way in, the feature reads
  # as "these tickets can't be deployed".

  def searchable_mrs
    [MergeRequest.new(iid: 11_203, title: 'Stolen wheels', source_branch: '15966-stolen-wheels',
                      author: Author.new(name: 'Alice'), state: 'opened'),
     MergeRequest.new(iid: 11_292, title: 'Driver GPS', source_branch: '16432-driver-gps',
                      author: Author.new(name: 'Bob'), state: 'opened')]
  end

  def get_index(params, client)
    with_client(client) { get '/deploy_review', params: { project: 'group/proj' }.merge(params) }
  end

  def test_index_search_narrows_the_list_to_the_matching_ticket
    get_index({ q: '16432' }, FakeClient.new(merge_requests: searchable_mrs))

    assert_match(/Driver GPS/, response.body)
    refute_match(/Stolen wheels/, response.body)
  end

  # The link GitLab knows and the branch name doesn't carry.
  def test_index_search_resolves_a_ticket_through_related_merge_requests
    related = { 99_999 => [MergeRequest.new(iid: 11_203, state: 'opened')] }
    get_index({ q: '99999' }, FakeClient.new(merge_requests: searchable_mrs, related: related))

    assert_match(/Stolen wheels/, response.body)
  end

  def test_index_search_with_no_match_says_so_instead_of_listing_everything
    get_index({ q: 'zzz-nothing' }, FakeClient.new(merge_requests: searchable_mrs))

    assert_response :success
    refute_match(/deploy-review-mr-/, response.body)
  end

  def test_index_keeps_the_query_in_the_search_field
    get_index({ q: '16432' }, FakeClient.new(merge_requests: searchable_mrs))

    assert_match(/name="q"[^>]*value="16432"|value="16432"[^>]*name="q"/, response.body)
  end

  def test_index_untracked_filter_hides_mrs_autodev_already_follows
    Issue.create!(project_path: 'group/proj', issue_iid: 15_966, mr_iid: 11_203, status: 'done')
    get_index({ untracked: '1' }, FakeClient.new(merge_requests: searchable_mrs))

    assert_match(/Driver GPS/, response.body)
    refute_match(/Stolen wheels/, response.body)
  end

  def test_index_lists_tracked_mrs_when_the_filter_is_off
    Issue.create!(project_path: 'group/proj', issue_iid: 15_966, mr_iid: 11_203, status: 'done')
    get_index({}, FakeClient.new(merge_requests: searchable_mrs))

    assert_match(/Stolen wheels/, response.body)
  end

  # The trigger redirect must land back on the same filtered view, or the CSM
  # is dumped into the 100-row list after every deploy.
  def test_trigger_redirect_preserves_the_search_and_filter
    with_outcome(Outcome.new(state: :triggered, action: :play)) do
      post '/deploy_review/mr', params: { project: 'group/proj', mr_iid: 5, q: '16432', untracked: '1' }
    end

    assert_redirected_to '/deploy_review?project=group%2Fproj&q=16432&untracked=1'
  end

  # === #availability ========================================================

  def test_availability_renders_the_frame_for_a_visible_project
    with_outcome(Outcome.new(state: :available, action: :play)) do
      get '/deploy_review/mr', params: { project: 'group/proj', mr_iid: 5 }
    end

    assert_response :success
    assert_match(/<turbo-frame[^>]*id="deploy-review-mr-group-proj-5"/, response.body)
  end

  def test_availability_is_forbidden_for_a_project_the_user_cannot_see
    get '/deploy_review/mr', params: { project: 'group/other', mr_iid: 5 }

    assert_response :forbidden
  end

  def test_availability_is_allowed_for_an_admin_on_any_project
    @user.update!(admin: true)

    with_outcome(Outcome.new(state: :no_job)) do
      get '/deploy_review/mr', params: { project: 'group/other', mr_iid: 5 }
    end

    assert_response :success
  end

  # === #trigger =============================================================

  def test_trigger_calls_the_service_flashes_and_records_audit
    assert_difference -> { AuditLog.where(action: 'deploy_review.manual').count }, 1 do
      with_outcome(Outcome.new(state: :triggered, action: :play)) do
        post '/deploy_review/mr', params: { project: 'group/proj', mr_iid: 5 }
      end
    end

    assert_redirected_to '/deploy_review?project=group%2Fproj'
    assert_predicate flash[:notice], :present?
  end

  def test_trigger_is_forbidden_for_a_project_the_user_cannot_see
    assert_no_difference -> { AuditLog.where(action: 'deploy_review.manual').count } do
      post '/deploy_review/mr', params: { project: 'group/other', mr_iid: 5 }
    end

    assert_response :forbidden
  end

  def test_trigger_unavailable_flashes_alert_and_records_no_audit
    assert_no_difference -> { AuditLog.where(action: 'deploy_review.manual').count } do
      with_outcome(Outcome.new(state: :no_job)) do
        post '/deploy_review/mr', params: { project: 'group/proj', mr_iid: 5 }
      end
    end

    assert_redirected_to '/deploy_review?project=group%2Fproj'
    assert_predicate flash[:alert], :present?
  end
end

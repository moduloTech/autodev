# frozen_string_literal: true

# Deploy-review surface for merge requests autodev never tracked (task #43).
#
# `Autodev::DeployReview` only ever reads 3 fields (project_path / branch_name
# / mr_iid), so it's driven here with an `Autodev::DeployReview::Target`
# value object instead of an `Issue` row — no change to the service itself.
#
# Unlike the issue-scoped surface (`IssuesController` + `DeployReviewActions`,
# whose access control is implicit in `issues_dataset` filtering by project
# membership), an arbitrary (project, mr_iid) pair has no such dataset to
# filter through — so `#authorize_project!` is the actual security boundary
# here, applied to `#availability` and `#trigger` (never rely on the UI only
# rendering visible projects: a crafted request could still hit either
# action directly).
class DeployReviewsController < ApplicationController
  include ::Web::Helpers

  before_action :authorize_project!, only: %i[availability trigger]

  # GET /deploy_review[?project=&q=&untracked=1]
  #
  # Always renders the project selector (scoped to current_user.visible_projects).
  # When `?project=` names a project the user can see, also lists its open MRs
  # (title/iid/source branch/author), each annotated with a lazy deploy/
  # redeploy probe and a "tracked by autodev" badge when a matching Issue row
  # exists. An unknown/forbidden project silently falls back to the bare
  # selector — this is read-only UI, not the security boundary (see above).
  #
  # `q` searches by ticket number, MR number or free text (Autodev::DeployReviewSearch);
  # `untracked=1` hides the MRs autodev already follows. Both exist because the
  # unfiltered list runs past 100 rows on a real project, which is what made the
  # surface unusable for a CSM arriving with a ticket number (Autodev #45).
  def index
    project_path = params[:project].presence
    merge_requests, error = index_merge_requests(project_path)
    tracked = tracked_issue_ids(project_path, merge_requests)

    render html: Web::Views::DeployReviews::Index.new(
      projects: current_user_visible_projects, selected_project: project_path,
      merge_requests: apply_untracked_filter(merge_requests, tracked), tracked_issue_ids: tracked,
      query: search_query, untracked_only: untracked_only?, error: error, kpis: dashboard_kpis,
      **view_kwargs
    ).call.html_safe, layout: false
  end

  # GET /deploy_review/mr?project=&mr_iid=
  #
  # Lazy turbo-frame probe — same contract as IssuesController#deploy_review
  # but targeting an arbitrary (project, mr_iid) instead of a tracked issue.
  def availability
    outcome = Autodev::DeployReview.new(build_target).availability
    render html: availability_frame(outcome).call.html_safe, layout: false
  end

  # POST /deploy_review/mr
  #
  # (Re)triggers the `deploy_review` job for the given (project, mr_iid),
  # flashes the result, records an audit row, and redirects back to the
  # project's MR list.
  def trigger
    apply_deploy_review_flash(Autodev::DeployReview.new(build_target).trigger!)
    redirect_to index_path_with_filters
  end

  private

  # Carries the search + filter back through the redirect, so a deploy doesn't
  # dump the user back into the unfiltered 100-row list.
  def index_path_with_filters
    query = { project: params[:project].to_s }
    query[:q] = search_query if search_query
    query[:untracked] = '1' if untracked_only?
    "/deploy_review?#{query.to_query}"
  end

  def search_query = params[:q].presence&.strip.presence

  def untracked_only? = params[:untracked].to_s == '1'

  # Applied here rather than in the search service: the tracked map is built
  # from the `issues` table, which is the controller's business, not GitLab's.
  def apply_untracked_filter(merge_requests, tracked)
    return merge_requests unless untracked_only? && merge_requests

    merge_requests.reject { |mr| tracked.key?(GitlabHelpers.field(mr, :iid)) }
  end

  def build_target
    Autodev::DeployReview::Target.new(
      project_path: params[:project], branch_name: nil, mr_iid: Integer(params[:mr_iid])
    )
  end

  def availability_frame(outcome)
    Web::Views::DeployReviewFrame.new(
      state: outcome.state, action: outcome.action,
      frame_id: Web::Views::DeployReviewFrame.mr_frame_id(params[:project], params[:mr_iid]),
      src: mr_frame_src, submit_action: '/deploy_review/mr',
      hidden_fields: { project: params[:project], mr_iid: params[:mr_iid] },
      **view_kwargs
    )
  end

  # nil/false pair (no project selected / not visible) short-circuits before
  # any GitLab call — mirrors #index's "silently fall back to the bare
  # selector" contract (see #index's doc comment).
  def index_merge_requests(project_path)
    return [nil, false] unless project_path && visible_project_path?(project_path)

    result = Autodev::DeployReviewSearch.new(
      client: gitlab_client, project_path: project_path,
      query: search_query, logger: Rails.logger
    ).call
    [result.merge_requests, result.error]
  end

  def current_user_visible_projects
    respond_to?(:current_user) && current_user ? current_user.visible_projects.order(:slug) : Project.none
  end

  def authorize_project!
    head :forbidden unless visible_project_path?(params[:project])
  end

  def visible_project_path?(project_path)
    admin_or_no_session? || visible_project_paths.include?(project_path)
  end

  def mr_frame_src
    "/deploy_review/mr?project=#{CGI.escape(params[:project].to_s)}&mr_iid=#{params[:mr_iid]}"
  end

  # Maps each listed MR's iid to the tracking Issue's id (for the "tracked by
  # autodev" badge + its link to the ticket). Every open MR is listed
  # regardless (deploy is idempotent, task #43 decision) — tracked ones are
  # annotated, not hidden.
  def tracked_issue_ids(project_path, merge_requests)
    return {} unless project_path && merge_requests.present?

    iids = merge_requests.map { |mr| GitlabHelpers.field(mr, :iid) }
    Issue.where(project_path: project_path, mr_iid: iids).pluck(:mr_iid, :id).to_h
  end

  def apply_deploy_review_flash(outcome)
    case outcome.state
    when :triggered
      flash_deploy_review_triggered(outcome)
    when :error
      flash_deploy_review_error(outcome)
    else # :no_branch / :no_pipeline / :no_job / :blocked / :running / :unknown
      flash[:alert] = t_web(Autodev::DeployReview.reason_key(outcome.state))
    end
  end

  def flash_deploy_review_error(outcome)
    # Log the raw GitLab error server-side; show a sanitized message — the
    # raw text can leak internal API endpoints / server errors.
    Rails.logger.warn("[deploy_reviews] trigger failed for #{params[:project]}!#{params[:mr_iid]}: " \
                      "#{outcome.message}")
    flash[:alert] = t_web(:web_flash_deploy_review_error)
  end

  def flash_deploy_review_triggered(outcome)
    key = outcome.action == :play ? :web_flash_deploy_review_played : :web_flash_deploy_review_retried
    flash[:notice] = t_web(key)
    Audit.record!(
      resource: Project.find_by(gitlab_path: params[:project]), action: 'deploy_review.manual',
      actor: current_user,
      payload: { project_path: params[:project], mr_iid: params[:mr_iid], action: outcome.action }
    )
  end

  def gitlab_client
    @gitlab_client ||= GitlabHelpers.build_gitlab_client(app_config['gitlab_url'], app_config['gitlab_token'])
  end
end

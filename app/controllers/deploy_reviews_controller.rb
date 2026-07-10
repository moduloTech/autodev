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

  # GET /deploy_review
  #
  # Always renders the project selector (scoped to current_user.visible_projects).
  # When `?project=` names a project the user can see, also lists its open MRs
  # (title/iid/source branch/author), each annotated with a lazy deploy/
  # redeploy probe and a "tracked by autodev" badge when a matching Issue row
  # exists. An unknown/forbidden project silently falls back to the bare
  # selector — this is read-only UI, not the security boundary (see above).
  def index
    project_path = params[:project].presence
    merge_requests, error = index_merge_requests(project_path)

    render html: Web::Views::DeployReviews::Index.new(
      projects: current_user_visible_projects, selected_project: project_path,
      merge_requests: merge_requests, tracked_issue_ids: tracked_issue_ids(project_path, merge_requests),
      error: error, kpis: dashboard_kpis,
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
    redirect_to "/deploy_review?project=#{CGI.escape(params[:project].to_s)}"
  end

  private

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

    fetch_open_merge_requests(project_path)
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

  # per_page: 100, no auto-pagination beyond that (v1 — see ticket's "points
  # d'attention": listing + probing every row is already several GitLab calls
  # per page load, the lazy per-row probe is what keeps that bounded).
  def fetch_open_merge_requests(project_path)
    mrs = gitlab_client.merge_requests(project_path, state: 'opened', per_page: 100)
    [mrs.to_a, false]
  rescue StandardError => e
    Rails.logger.warn("[deploy_reviews] failed to list MRs for #{project_path}: #{e.class}: #{e.message}")
    [[], true]
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

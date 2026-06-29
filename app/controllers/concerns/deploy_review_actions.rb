# frozen_string_literal: true

# Review-environment redeploy actions for IssuesController. Extracted into a
# concern so the controller stays focused on the core issue lifecycle.
#
# Relies on the host controller's `Web::Helpers` (find_issue, view_kwargs,
# t_web) and Devise (current_user). See `Autodev::DeployReview` for the GitLab
# interaction and `Web::Views::DeployReviewFrame` for the lazy turbo-frame.
module DeployReviewActions
  extend ActiveSupport::Concern

  # GET /issues/:id/deploy_review
  #
  # Lazy turbo-frame target. Probes the branch's latest pipeline for a
  # `deploy_review` job and renders the frame with an enabled button (job
  # present) or a disabled button + reason (no branch/pipeline/job, or a
  # GitLab error). Read-only — every signed-in user may load it.
  def deploy_review
    issue = find_issue(params[:id])
    return head :not_found unless issue

    outcome = Autodev::DeployReview.new(issue).availability
    html = Web::Views::DeployReviewFrame.new(
      issue_id: issue.id, state: outcome.state, action: outcome.action, **view_kwargs
    ).call
    render html: html.html_safe, layout: false
  end

  # POST /issues/:id/deploy_review
  #
  # (Re)triggers the `deploy_review` job — played if still manual, retried if
  # already run — then redirects to the issue with a flash. The form targets
  # `_top`, so this is a full-page navigation, not a frame swap.
  def trigger_deploy_review
    issue = find_issue(params[:id])
    return head :not_found unless issue

    apply_deploy_review_flash(issue, Autodev::DeployReview.new(issue).trigger!)
    redirect_to "/issues/#{issue.id}"
  end

  private

  def apply_deploy_review_flash(issue, outcome)
    case outcome.state
    when :triggered
      flash_deploy_review_triggered(issue, outcome)
    when :error
      # Log the raw GitLab error server-side; show a sanitized message — the
      # raw text can leak internal API endpoints / server errors.
      Rails.logger.warn("[deploy_review] trigger failed for issue ##{issue.id}: #{outcome.message}")
      flash[:alert] = t_web(:web_flash_deploy_review_error)
    else # :no_branch / :no_pipeline / :no_job / :blocked / :running / :unknown
      flash[:alert] = t_web(Autodev::DeployReview.reason_key(outcome.state))
    end
  end

  def flash_deploy_review_triggered(issue, outcome)
    key = outcome.action == :play ? :web_flash_deploy_review_played : :web_flash_deploy_review_retried
    flash[:notice] = t_web(key)
    Audit.record!(resource: issue, action: 'issue.deploy_review', actor: current_user,
                  payload: { project_path: issue.project_path, branch: issue.branch_name, action: outcome.action })
  end
end

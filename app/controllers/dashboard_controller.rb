# frozen_string_literal: true

# Ported off Sinatra's `get '/'`. Aggregates 5 datasets (active issues,
# errored, kpis, weekly_activity, by_project) into a single Phlex view.
class DashboardController < ApplicationController
  include ::Web::Helpers

  # GET /
  def show
    render html: render_dashboard.html_safe, layout: false
  end

  private

  def render_dashboard
    ::Web::Views::Dashboard.new(
      active: active_issues,
      errored: errored_issues,
      kpis: dashboard_kpis,
      weekly_activity: weekly_activity_counts,
      by_project: project_breakdown,
      anthropic_configured: Autospec::Chat.api_key_configured?,
      drafts_awaiting_my_vote: drafts_awaiting_my_vote,
      **view_kwargs
    ).call
  end

  # Failed requests behind the dashboard's red "X demandes ont échoué" banner,
  # which links to /issues?tab=errors and offers a one-click retry — so it
  # counts only `error` rows (the retryable ones), not the waiting /
  # delivered-review concerns that now live in their own tabs. Scoped via
  # issues_dataset for non-admin users.
  def errored_issues
    issues_dataset.where(status: 'error').order(id: :desc).to_a
  end

  # AutoSpec drafts in pending_approval on projects the current user
  # owns AND on which the user hasn't yet voted at the current
  # iteration. Surfaces them on the dashboard as a CTA so owners
  # don't have to remember to look. Returns [] for users who aren't
  # owner of any project — the dashboard widget is hidden in that case.
  def drafts_awaiting_my_vote # rubocop:disable Metrics/MethodLength
    return [] if current_user.nil?

    owned_project_ids = current_user
                        .project_memberships
                        .where(role: ProjectMembership::ROLE_OWNER)
                        .select(:project_id)
    drafts = AutospecDraft.where(status: AutospecDraft::STATUS_PENDING_APPROVAL,
                                 project_id: owned_project_ids)
                          .includes(:project, :user)
                          .order(updated_at: :desc)
    # Per-iteration filter (the `exists?` is per-row but the list is
    # capped to the owner's project set so the N+1 stays small —
    # typically 0-20 rows in production).
    drafts.reject do |d|
      d.autospec_approvals.exists?(user: current_user, iteration: d.current_iteration)
    end
  end
end

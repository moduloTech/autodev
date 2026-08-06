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
    ::Web::Views::Dashboard.new(**dashboard_datasets, **view_kwargs).call
  end

  def dashboard_datasets
    {
      active: active_issues,
      errored: errored_issues,
      kpis: dashboard_kpis,
      weekly_activity: weekly_activity_counts,
      by_project: project_breakdown,
      anthropic_configured: Autospec::Chat.api_key_configured?,
      drafts_awaiting_my_vote: drafts_awaiting_my_vote,
      # Passive read of the last quota probe (Autodev #46) — no live
      # danger-claude call on a page render.
      usage_state: Autodev::UsageGate.state(config: app_config)
    }
  end

  # Failed requests behind the dashboard's red "X demandes ont échoué" banner,
  # which links to /issues?tab=errors and offers a one-click retry — so it
  # counts only `error` rows (the retryable ones), not the waiting /
  # delivered-review concerns that now live in their own tabs. Scoped via
  # issues_dataset for non-admin users.
  def errored_issues
    issues_dataset.where(status: 'error').order(id: :desc).to_a
  end

  # AutoSpec drafts awaiting the current user's vote — surfaced on the
  # dashboard as a CTA so owners don't have to remember to look. Same set as
  # the /autospec_drafts "À valider" tab and the sidebar badge (shared
  # `AutospecDraft.awaiting_vote_of`). Empty for users who own no project.
  def drafts_awaiting_my_vote
    AutospecDraft.awaiting_vote_of(current_user)
  end
end

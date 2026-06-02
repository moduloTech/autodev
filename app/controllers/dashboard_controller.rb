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
      locale: web_locale,
      request_path: request.fullpath
    ).call
  end

  # Same query as ErrorsController#index — status in
  # (error, needs_clarification) OR post_completion_error IS NOT NULL,
  # id desc. Inlined here rather than shared via a model scope because
  # the Sequel `Issue` model gets rewritten in phase C; phase B keeps
  # the porting layer thin.
  def errored_issues
    issues_dataset.where(status: %w[error needs_clarification])
                  .or(Sequel.~(post_completion_error: nil))
                  .order(Sequel.desc(:id))
                  .all
  end
end

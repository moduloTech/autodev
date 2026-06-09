# frozen_string_literal: true

# Ported off Sinatra's `get '/errors'`. Same data shape, same view.
class ErrorsController < ApplicationController
  include ::Web::Helpers

  # GET /errors
  def index
    render html: render_errors_view.html_safe, layout: false
  end

  private

  def render_errors_view
    ::Web::Views::Errors.new(
      errored: errored_issues,
      kpis: dashboard_kpis,
      **view_kwargs
    ).call
  end

  # status in (error, needs_clarification) OR post_completion_error IS NOT NULL,
  # ordered by id desc. Scoped via issues_dataset for non-admin users.
  def errored_issues
    issues_dataset
      .where("status IN ('error', 'needs_clarification') OR post_completion_error IS NOT NULL")
      .order(id: :desc)
      .to_a
  end
end

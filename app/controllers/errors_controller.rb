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

  # The "À surveiller" set: anything needing a human. status in
  # (error, needs_clarification) OR a failed post-completion hook OR a
  # "gave-up done" issue flagged needs_attention (review limit / review
  # failures / stagnation). Ordered by id desc, scoped via issues_dataset.
  def errored_issues
    issues_dataset
      .where("status IN ('error', 'needs_clarification') OR post_completion_error IS NOT NULL " \
             'OR needs_attention = ?', true)
      .order(id: :desc)
      .to_a
  end
end

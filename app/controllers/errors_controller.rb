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
      locale: web_locale,
      request_path: request.fullpath
    ).call
  end

  # Mirrors the Sinatra query: status in (error, needs_clarification)
  # OR post_completion_error IS NOT NULL, ordered by id desc.
  def errored_issues
    Issue.where("status IN ('error', 'needs_clarification') OR post_completion_error IS NOT NULL")
         .order(id: :desc)
         .to_a
  end
end

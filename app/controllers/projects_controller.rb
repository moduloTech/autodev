# frozen_string_literal: true

# Ported off Sinatra's `get '/projects'` (index) and
# `get '/projects/:slug'` (show). Index: union semantics
# (YAML config + DB-distinct paths), zero-filled placeholder for
# configured-but-quiet projects. Show: decode slug via project_unslug,
# render the same page even for unknown projects (Sinatra parity).
class ProjectsController < ApplicationController
  include ::Web::Helpers

  # GET /projects
  def index
    render html: render_projects_view.html_safe, layout: false
  end

  # GET /projects/:slug
  #
  # Ported from `get '/projects/:slug'` in lib/autodev/web/server.rb.
  # No 404 on missing project (Sinatra parity): an unknown slug still
  # renders the page with empty issues + zero stats + empty config.
  def show
    project_path = project_unslug(params[:slug])
    render html: render_project_show(project_path).html_safe, layout: false
  end

  private

  def render_project_show(project_path)
    ::Web::Views::ProjectShow.new(
      project_path: project_path,
      project_config: project_for(project_path),
      project_issues: project_issues_for(project_path),
      stats: project_overview_stats(project_path),
      kpis: dashboard_kpis,
      tab: params[:tab].to_s,
      locale: web_locale,
      request_path: request.fullpath
    ).call
  end

  def project_issues_for(project_path)
    Issue.where(project_path: project_path)
         .order(id: :desc).limit(100).to_a
  end

  def render_projects_view
    ::Web::Views::ProjectsIndex.new(
      projects: projects_with_stats,
      kpis: dashboard_kpis,
      locale: web_locale,
      request_path: request.fullpath
    ).call
  end

  # Mirrors the Sinatra block: stats from project_breakdown when the
  # project has issues, zero-filled placeholder otherwise. Order
  # follows all_known_projects (YAML config order then DB-only paths,
  # both alphabetical inside their group).
  def projects_with_stats
    stats_by_path = project_breakdown.to_h { |s| [s[:path], s] }
    all_known_projects.map do |path|
      stats_by_path[path] || { path: path, total: 0, active: 0, done: 0, error: 0 }
    end
  end
end

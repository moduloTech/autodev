# frozen_string_literal: true

# Phase B of the railsification (cf. autodev/docs/autospec.md §D).
#
# Rails-native routes are added above the catch-all `mount` line as we
# port them off Sinatra. Rails router matches top-down, so anything not
# matched here falls through to Web::Server, the legacy Sinatra app
# wired up in config/initializers/legacy_sinatra.rb.
Rails.application.routes.draw do
  # === Ported routes ===============================================
  # /issues/:id (both HTML + .json) → IssuesController#show via respond_to.
  # /issues/:id/reset → IssuesController#reset (raw SQL reset, not AASM).
  # /issues/:id/transition → IssuesController#transition (AASM event!).
  # /errors → ErrorsController#index (errored + needs_clarification + post_completion_error).
  # /projects → ProjectsController#index (union of YAML config + DB-distinct paths).
  # /projects/:slug → ProjectsController#show (slug = group__project, decoded via project_unslug).
  # /list/:status → ListController#show (filter all issues by status, limit 500).
  # / → DashboardController#show (5 datasets aggregated into the Dashboard view).
  # /issues → IssuesController#index (paginated + filterable list).
  # /stream → StreamController#show (Server-Sent Events via
  # ActionController::Live, subscribes to Web::EventBus).
  # /locale/:lang → LocaleController#update (sets/clears the locale cookie + redirect).
  # Sinatra still owns /assets/* only (vendored Turbo + CSS + fonts —
  # ported when the Rails asset pipeline is set up in phase C).
  root                           to: 'dashboard#show'
  get  '/issues',                to: 'issues#index'
  get  '/issues/:id',            to: 'issues#show',       constraints: { id: /\d+/ }
  post '/issues/:id/reset',      to: 'issues#reset',      constraints: { id: /\d+/ }
  post '/issues/:id/transition', to: 'issues#transition', constraints: { id: /\d+/ }
  get  '/errors',                to: 'errors#index'
  get  '/projects',              to: 'projects#index'
  get  '/projects/:slug',        to: 'projects#show'
  get  '/list/:status',          to: 'list#show'
  get  '/stream',                to: 'stream#show'
  get  '/locale/:lang',          to: 'locale#update'

  # === Catch-all to Sinatra ========================================
  mount Web::Server => '/' if defined?(Web::Server)
end

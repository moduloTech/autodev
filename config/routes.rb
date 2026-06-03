# frozen_string_literal: true

# Phase B of the railsification — complete (cf. autodev/docs/autospec.md §D).
#
# Every URL the embedded dashboard serves is Rails-native. The legacy
# Sinatra `Web::Server` still loads (the `bin/autodev` entry point uses it
# end-to-end), but `bin/rails server` no longer mounts it: there is no
# catch-all fallback in this routes file. Unknown paths 404 from Rails.
#
# Phase C will delete `lib/autodev/web/` entirely once the poller has moved
# to Solid Queue. Until then the directory stays in place for `bin/autodev`.
Rails.application.routes.draw do
  # === Devise / Entra ID SSO (step 3) ==============================
  # /users/auth/entra_id           → omniauth strategy (redirect to Entra)
  # /users/auth/entra_id/callback  → Users::OmniauthCallbacksController#entra_id
  # /users/sign_out                → Devise sessions#destroy (logout)
  # No sign_in form is rendered — there is no local-password flow. We pass
  # `skip: [:registrations, :passwords]` because those modules aren't wired
  # on User; declaring them in routes would 404 on visit anyway, but keeping
  # the route file accurate avoids confusion.
  devise_for :users,
             skip: %i[registrations passwords],
             controllers: { omniauth_callbacks: 'users/omniauth_callbacks' }

  # === Application routes ==========================================
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

  # === Static assets ===============================================
  # Same URL space + content-types + cache-control as the matching
  # Sinatra routes in lib/autodev/web/server.rb (which still serve them
  # for the `bin/autodev` standalone entry point). Source files live
  # under lib/autodev/web/public/; propshaft/sprockets is intentionally
  # deferred to attack-order step 8 (Phlex view port + asset pipeline).
  get '/assets/turbo.js',                        to: 'assets#turbo_js'
  get '/assets/css/:name.css',                   to: 'assets#css',  constraints: { name: /[a-z0-9_-]+/ }
  get '/assets/vendor/fonts/:name.woff2',        to: 'assets#font', constraints: { name: /[A-Za-z0-9_-]+/ }
end

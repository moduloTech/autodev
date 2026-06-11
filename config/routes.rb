# frozen_string_literal: true

# Post-railsification routes. Every URL the embedded dashboard serves is
# Rails-native; `lib/autodev/web/` (the legacy Sinatra app) is gone.
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

  # Anonymous sign-in landing — rendered by `SignInController#new`,
  # POSTs to `/users/auth/entra_id`. Kicked off by Devise's failure_app
  # redirect (config/initializers/devise.rb). Anonymous-accessible.
  get '/sign_in', to: 'sign_in#new'

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
  # Single catch-all that resolves via Propshaft's load_path (cf.
  # AssetsController). Replaces three earlier per-pattern routes
  # (`/assets/turbo.js`, `/assets/css/:name.css`,
  # `/assets/vendor/fonts/:name.woff2`) — and also handles Mission
  # Control's digested URLs (`/assets/mission_control/jobs/application-<sha>.css`,
  # `/assets/turbo.min-<sha>.js`, …) which the gem's `stylesheet_link_tag` /
  # `javascript_importmap_tags` helpers emit.
  get '/assets/*path', to: 'assets#show', format: false

  # === Admin =======================================================
  # /admin/users — read-only audit of users × memberships (PR2 of the
  # users-rollout chantier). Guarded by `current_user&.admin?` in the
  # controller until PR3 turns on the global authenticate_user!.
  get '/admin/users', to: 'admin/users#index'

  # Mission Control — Jobs: Solid Queue inspector + administration UI.
  # No auth gate (cf. config/initializers/mission_control.rb) — same
  # 127.0.0.1 / NetBird mesh trust model as the rest of the dashboard.
  mount MissionControl::Jobs::Engine, at: '/admin/jobs'
end

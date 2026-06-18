# frozen_string_literal: true

# Post-railsification routes. Every URL the embedded dashboard serves is
# Rails-native; `lib/autodev/web/` (the legacy Sinatra app) is gone.
Rails.application.routes.draw do # rubocop:disable Metrics/BlockLength
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

  # The User model only declares `:trackable, :omniauthable` (no
  # `:database_authenticatable`), so `devise_for :users` does not emit the
  # `sessions` resource and `/users/sign_out` would 404. Wire it explicitly
  # to a custom controller that calls Devise's `sign_out` helper.
  delete '/users/sign_out', to: 'users/sessions#destroy', as: :destroy_user_session

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
  # /issues/:id/close → IssuesController#close (manual close by a project
  # collaborator; AASM `close` event, gated on project membership).
  post '/issues/:id/close',      to: 'issues#close',      constraints: { id: /\d+/ }
  get  '/errors',                to: 'errors#index'
  get  '/projects',              to: 'projects#index'
  get  '/projects/:slug',        to: 'projects#show'
  get  '/stream',                to: 'stream#show'
  get  '/locale/:lang',          to: 'locale#update'

  # === AutoSpec (phase D step 9c-10a) ==============================
  # index / new / create / show, plus :member POST routes for chat
  # (HTML redirect or JSON) and apply_suggestion (idempotent, 409 on
  # re-apply). Token-level SSE streaming on chat deferred per
  # autospec.md §L — see AutospecDraftsController for the rationale.
  resources :autospec_drafts, only: %i[index new create show update], constraints: { id: /\d+/ } do
    collection do
      get  :import
      post :import, action: :create_from_import, as: :create_from_import
    end
    post :chat,                on: :member
    post :apply_suggestion,    on: :member
    post :submit_for_approval, on: :member
    post :retract,             on: :member
    post :approve,             on: :member
    post :reject,              on: :member
    resources :autospec_attachments, only: %i[create destroy], constraints: { id: /\d+/ }
  end

  # In-app help — renders `docs/usage/autodev-functional-usage.md` as HTML
  # (same source the operator builds the PDF from via `md2pdf`). The
  # markdown references screenshots under `docs/usage/screenshots/`; those
  # are served by `#image` rather than the asset pipeline because they are
  # documentation assets, not Propshaft-managed.
  get '/help',                   to: 'help#show'
  get '/help/images/:filename',  to: 'help#image', constraints: { filename: /[\w\-.]+/ }

  # === Static assets ===============================================
  # Single catch-all that resolves via Propshaft's load_path (cf.
  # AssetsController). Replaces three earlier per-pattern routes
  # (`/assets/turbo.js`, `/assets/css/:name.css`,
  # `/assets/vendor/fonts/:name.woff2`) — and also handles Mission
  # Control's digested URLs (`/assets/mission_control/jobs/application-<sha>.css`,
  # `/assets/turbo.min-<sha>.js`, …) which the gem's `stylesheet_link_tag` /
  # `javascript_importmap_tags` helpers emit.
  get '/assets/*path', to: 'assets#show', format: false

  # === Monitoring (unauthenticated — for external probes) ==========
  # /up        → Rails' own liveness endpoint (process boots + responds).
  # /healthz   → Autodev::HealthReport as JSON; HTTP 200 if ok else 503.
  # /healthz/:check → a single component (poller, workers, queue, …).
  # These skip the SSO gate (cf. MonitoringController) so Datadog /
  # BetterStack can scrape them; an optional `monitoring.token` gates access.
  get '/up', to: 'rails/health#show'
  get '/healthz', to: 'monitoring#show', defaults: { format: :json }
  get '/healthz/:check', to: 'monitoring#component', defaults: { format: :json },
                         constraints: { check: /poller|workers|queue|claude_usage|issues_error|database/ }

  # === Admin =======================================================
  # /admin/users — read-only audit of users × memberships (PR2 of the
  # users-rollout chantier). Guarded by `current_user&.admin?` in the
  # controller until PR3 turns on the global authenticate_user!.
  get '/admin/users', to: 'admin/users#index'

  # /admin/help — same in-app rendering as /help but for the technical
  # guide (`docs/usage/autodev-technical-usage.md`). Admin-gated via
  # AdminApplicationController. Image refs in both docs point at
  # /help/images/* — that endpoint is shared and lives on HelpController.
  get '/admin/help', to: 'admin/help#show'

  # /admin/health — system health dashboard (Autodev::HealthReport). Human
  # view of the same data the unauthenticated /healthz endpoints serve.
  get '/admin/health', to: 'admin/health#show'

  # Mission Control — Jobs: Solid Queue inspector + administration UI.
  # No auth gate (cf. config/initializers/mission_control.rb) — same
  # 127.0.0.1 / NetBird mesh trust model as the rest of the dashboard.
  mount MissionControl::Jobs::Engine, at: '/admin/jobs'
end

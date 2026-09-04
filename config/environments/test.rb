# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = false
  config.consider_all_requests_local = true
  config.active_support.deprecation = :stderr

  # CSRF protection off in tests so controller specs can POST without
  # forging a token. Production keeps the default `protect_from_forgery
  # with: :exception` on ApplicationController.
  config.action_controller.allow_forgery_protection = false

  # ActiveStorage uses a per-process tmp dir under tmp/storage/ — see
  # storage.yml. rails_helper.rb's TABLES wipe handles the DB rows; the
  # files themselves are cleaned up when the test process exits.
  config.active_storage.service = :test

  # Override the global :solid_queue adapter (set in config/application.rb)
  # with ActiveJob's TestAdapter. Two reasons: (1) test/rails_helper.rb only
  # migrates the primary DB — the queue DB stays empty, so any
  # ActiveJob.perform_later would crash with
  # `Could not find table 'solid_queue_jobs'`; (2) the existing job tests
  # stub `#perform` directly anyway, so capturing-without-running is the
  # right semantics here. ActiveStorage's `AnalyzeJob` (fired on every
  # `Blob#attach` for analyzable content) is the most common implicit
  # enqueue path — without this override, AutospecAttachmentTest fails.
  config.active_job.queue_adapter = :test

  # Autodev #112's real-server proof (test/sse_shutdown_test.rb) boots this
  # app's own `puma -C config/puma.rb` as a genuinely separate OS process,
  # against a throwaway file-backed primary DB. Two things a bare `puma -C
  # config/puma.rb` boot does not give it, both gated so neither can engage
  # anywhere else: test env only, and only when the harness sets
  # `AUTODEV_SSE_TEST_HARNESS` on the spawned process's environment. An
  # ordinary `rake test` run never sets it, so this whole block is a no-op
  # for the rest of the suite.
  if ENV['AUTODEV_SSE_TEST_HARNESS']
    require 'warden/test/helpers'
    Warden.test_mode!
    config.to_prepare do
      # 1. Migrations. This process boots straight off `config/environment`
      # (via `puma -C config/puma.rb`), not through `test/test_helper.rb`,
      # so nothing else has migrated `AUTODEV_DB` yet —
      # `config/initializers/auto_migrate.rb` skips itself unconditionally
      # in the test env. Needed unconditionally, whether or not a login is
      # requested below: without it there is no `sessions` table for
      # `ActiveRecord::SessionStore` either, and an unauthenticated request
      # needs that table just as much as an authenticated one does. Safe to
      # re-run: every `create_table` migration is idempotent.
      ActiveRecord::MigrationContext.new(Rails.root.join('db/migrate').to_s).migrate

      # 2. The login shortcut itself, only when requested. Devise's real
      # sign-in needs a full Entra ID + GitLab-sync round trip, which
      # `test/controllers/users/omniauth_callbacks_controller_test.rb`
      # already declined for this exact controller action, in its own
      # words: "The OmniAuth test_mode plumbing is fragile under Devise +
      # omniauth-rails_csrf_protection and our pared-down railtie set" — and
      # it would also need a live GitLab here
      # (`GitlabMembershipSync.for_user!` runs synchronously in the
      # callback). Warden's own test-mode login stands in instead.
      login_email = ENV.fetch('AUTODEV_WARDEN_TEST_LOGIN_EMAIL', nil)
      if login_email
        user = User.find_or_create_by!(email: login_email)

        # Same call `Warden::Test::Helpers#login_as` makes — queues the
        # proxy to authenticate this user on the very next request Warden
        # sees.
        Warden.on_next_request { |proxy| proxy.set_user(user, scope: :user, event: :authentication) }
      end
    end
  end
end

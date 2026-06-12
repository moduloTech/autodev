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
end

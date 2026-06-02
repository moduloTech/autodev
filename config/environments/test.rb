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
end

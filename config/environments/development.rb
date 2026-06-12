# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = true
  config.eager_load = false
  config.consider_all_requests_local = true
  config.active_support.deprecation = :stderr
  config.active_record.migration_error = :page_load
  config.active_record.verbose_query_logs = true

  # ActiveStorage (phase D step 9 — AutoSpec attachments). Local disk under
  # <Rails.root>/storage/ — same machine as the SQLite files. See storage.yml.
  config.active_storage.service = :local
end

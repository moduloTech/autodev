# frozen_string_literal: true

# Apply any pending ActiveRecord migrations at boot, so that:
#   - `bin/rails server` doesn't 500 with `PendingMigrationError` in dev
#     (Rails 8's `Migration::CheckPending` middleware fires when files exist
#     in `db/migrate/` but `schema_migrations` is empty).
#   - End users who `brew upgrade autodev` and run `bin/rails server` get the
#     new tables auto-created without a separate manual step.
#
# Safe to do here because Autodev is a single-user, single-SQLite-file CLI:
# no concurrent writers and no shared production database. `migrate` is
# idempotent — re-running after everything is applied is a no-op.
#
# Skipped when:
#   - AUTODEV_SKIP_AUTO_MIGRATE=1 (for explicit control in tests / scripts)
#   - test env (test/rails_helper.rb migrates against the in-memory test DB
#     explicitly, and we don't want this to fire before the connection has
#     been switched onto `:memory:`).

return if ENV['AUTODEV_SKIP_AUTO_MIGRATE']
return if Rails.env.test?

Rails.application.config.after_initialize do
  ActiveRecord::Base.establish_connection
  ActiveRecord::MigrationContext.new(Rails.root.join('db/migrate').to_s).migrate
rescue StandardError => e
  Rails.logger.warn("[auto_migrate] migration failed: #{e.class}: #{e.message}")
end

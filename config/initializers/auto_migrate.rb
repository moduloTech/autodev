# frozen_string_literal: true

# Apply any pending ActiveRecord migrations at boot, so that:
#   - `bin/rails server` doesn't 500 with `PendingMigrationError` in dev
#     (Rails 8's `Migration::CheckPending` middleware fires when files exist
#     in `db/migrate/` but `schema_migrations` is empty).
#   - End users who `brew upgrade autodev` and run `bin/rails server` get the
#     new tables auto-created without a separate manual step.
#
# Two databases since step 5: business data on ApplicationRecord's pool
# (primary, ~/.autodev/autodev.db), Solid Queue on its own pool (queue,
# ~/.autodev/autodev_queue.db). Migration files use unqualified `create_table`
# which resolves to `ActiveRecord::Base.connection.create_table` — so for the
# queue migrations to land in the right file we explicitly point
# `ActiveRecord::Base` at each pool in turn, then restore primary at the end.
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
  configs = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env)

  configs.each do |db_config|
    paths = Array(db_config.migrations_paths || 'db/migrate')
            .map { |p| Rails.root.join(p).to_s }
    ActiveRecord::Base.establish_connection(db_config)
    ActiveRecord::MigrationContext.new(paths).migrate
  rescue StandardError => e
    Rails.logger.warn(
      "[auto_migrate] #{db_config.name} migration failed: #{e.class}: #{e.message}"
    )
  end

  # Restore the primary connection on ActiveRecord::Base so any model that
  # looks up ActiveRecord::Base.connection finds the primary DB.
  primary = configs.find { |c| c.name == 'primary' }
  ActiveRecord::Base.establish_connection(primary) if primary
end

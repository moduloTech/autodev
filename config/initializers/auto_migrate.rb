# frozen_string_literal: true

# Deliberately ABOVE the guards below: everything after them is skipped in the
# test environment and under AUTODEV_SKIP_AUTO_MIGRATE, but `Autodev::HealthReport`
# needs the constant in every environment for its `migrations` check. Do not move
# this require below the returns (Autodev #55).
require 'autodev/migration_status'

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
# Concurrency (Autodev #55 — this paragraph used to claim there were "no
# concurrent writers", which the supervisor invalidated long ago). `bin/autodev`
# requires `config/environment` before it reaches `run_supervisor`, so the parent
# plays this pass FIRST and alone; it then spawns `bin/rails server` and
# `bin/jobs start`, each of which boots its own Rails app against the same file
# and plays the pass again. Those two are no-ops in the normal case, and they are
# kept as the safety net for a child restarted on its own after an upgrade.
#
# When they are not no-ops, SQLite offers no help: `supports_advisory_locks?` is
# `false`, so Rails does not serialise two migrators. DDL is transactional, so
# the loser of such a race fails on `duplicate column name` or on the UNIQUE
# insert into `schema_migrations` — expected, and harmless, because the winner
# created the column. `Autodev::MigrationStatus.benign_race?` is what recognises
# those, and anything else is logged as an error instead. Either way this
# initializer never raises: it is on the boot path of `bin/rails runner`, of
# `autodev --status` / `--errors` / `--reset`, of a standalone `bin/rails server`
# and of the test suite — the very tools needed to diagnose a broken schema. The
# hard refusal lives in `bin/autodev`, which gates on
# `MigrationStatus.incomplete_schema_report` (a set difference, not this
# heuristic) before spawning any child; the `migrations` card on `/admin/health`
# reports the same condition for the entry points that do boot.
#
# `migrate` is idempotent — re-running after everything is applied is a no-op.
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
    # `failure_report` classifies (warn for a boot race, error otherwise) and
    # never raises — an exception escaping this rescue would abort the loop with
    # ActiveRecord::Base still pointed at the queue pool. It lives in
    # Autodev::MigrationStatus because this file is the one thing here no test can
    # execute, so everything but the two lines below is covered there.
    level, message = Autodev::MigrationStatus.failure_report(db_config, e)
    Rails.logger.public_send(level, message)
  end

  # Restore the primary connection on ActiveRecord::Base so any model that
  # looks up ActiveRecord::Base.connection finds the primary DB.
  primary = configs.find { |c| c.name == 'primary' }
  ActiveRecord::Base.establish_connection(primary) if primary
end

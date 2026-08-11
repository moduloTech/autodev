# frozen_string_literal: true

module Autodev
  # The two questions `config/initializers/auto_migrate.rb` used to conflate into
  # a single `rescue StandardError` + `warn` (Autodev #55).
  #
  #   Q1 `benign_race?` — was this exception a boot-race artifact? A heuristic
  #      over the message. Under the supervisor two Rails apps boot back to back
  #      against the same SQLite file, and SQLite reports
  #      `supports_advisory_locks? == false`, so Rails does not serialise the two
  #      migrators: the loser fails on `duplicate column name` or on the UNIQUE
  #      insert into `schema_migrations`, and in both cases the winner already did
  #      the work. This only ever picks a log level, so it is deliberately
  #      generous towards "benign" — a wrong answer costs one line written at the
  #      wrong severity and nothing else.
  #
  #   Q2 `pending` / `incomplete_schema_report` — is the schema complete? The
  #      versions parsed from the migration files minus the versions recorded in
  #      `schema_migrations`, per database. Not a heuristic: a set difference
  #      between two exact sets, read *after* the pass instead of inferred from
  #      it. This is the only predicate that gates anything — `bin/autodev`
  #      refuses to spawn the supervisor's children on a non-empty answer — which
  #      is why the classification above must never be allowed to reach it.
  #
  # The decoupling is the point. A benign race yields a Q1-benign exception *and*
  # an empty Q2 answer; a fatal failure yields an exception Q1 may misclassify
  # *and* a non-empty Q2 answer. So no misclassification can abort a boot, and
  # none can hide an incomplete schema.
  #
  # Lives in lib/ rather than app/services/ because the initializer needs it: a
  # plain `require` is deterministic in every environment, where referencing a
  # Zeitwerk-autoloaded constant from `after_initialize` is a behaviour this repo
  # cannot exercise (the initializer returns early in test, and development /
  # production point at the real ~/.autodev/autodev.db).
  module MigrationStatus
    # Matched against the exception message *and* its cause — ActiveRecord wraps
    # the adapter exception, and depending on the path the SQLite text sits on one
    # or the other. `already exists` covers both tables and indexes; it is broad on
    # purpose (see the class comment on why generous is the safe direction here).
    BENIGN_RACE_PATTERNS = [
      /duplicate column name/i,
      /already exists/i,
      /UNIQUE constraint failed:\s*schema_migrations/i
    ].freeze

    # The pool each configured database is reachable through, without ever calling
    # `establish_connection` — that is a boot-time hack `auto_migrate.rb` can
    # afford and a health check running inside a live request cannot. `queue` is
    # the pool `config.solid_queue.connects_to` binds to `SolidQueue::Record`.
    PRIMARY_DATABASE = 'primary'
    QUEUE_DATABASE = 'queue'

    class << self
      def benign_race?(error)
        return true if error.is_a?(::ActiveRecord::ConcurrentMigrationError)

        text = "#{error.message} #{error.cause&.message}"
        BENIGN_RACE_PATTERNS.any? { |pattern| text.match?(pattern) }
      end

      # { 'primary' => [version, ...] } — databases with nothing pending are
      # omitted, so `{}` means the schema is complete. A database that cannot be
      # read at all is treated as complete: this answer gates the supervisor's
      # boot, and failing to *observe* the schema must never be what stops
      # autodev. An unreachable database is the `database` health check's job to
      # report, not this one's.
      def pending
        database_configs.filter_map do |db_config|
          versions = begin
            pending_versions(db_config)
          rescue StandardError
            []
          end
          [db_config.name, versions] if versions.any?
        end.to_h
      end

      # Raises on an unreadable database, unlike #pending — callers that want the
      # fail-open behaviour go through #pending.
      def pending_versions(db_config)
        connection = connection_for(db_config.name)
        return [] unless connection

        migration_versions(db_config) - applied_versions(connection)
      end

      # nil when every migration on disk is recorded; otherwise a message ready to
      # print as the reason autodev refuses to start.
      def incomplete_schema_report
        outstanding = pending
        return nil if outstanding.empty?

        "#{outstanding.map { |name, versions| describe(name, versions) }.join('; ')}. " \
          'Autodev will not start on an incomplete schema: every job would fail on the missing column. ' \
          'Look for the [auto_migrate] lines in the log — most often another process held the SQLite ' \
          'write lock for the whole pass. Fix that and restart, or apply the migration by hand with ' \
          '`bin/rails db:migrate`.'
      end

      private

      def describe(name, versions)
        "#{versions.size} migration(s) not applied on #{name} (#{versions.join(', ')})"
      end

      def database_configs
        ::ActiveRecord::Base.configurations.configs_for(env_name: ::Rails.env)
      end

      def connection_for(name)
        case name
        when PRIMARY_DATABASE then ::ActiveRecord::Base.connection
        when QUEUE_DATABASE then defined?(::SolidQueue::Record) ? ::SolidQueue::Record.connection : nil
        end
      end

      # Filename parsing only — MigrationContext#migrations touches no connection.
      def migration_versions(db_config)
        paths = Array(db_config.migrations_paths || 'db/migrate').map { |path| ::Rails.root.join(path).to_s }
        ::ActiveRecord::MigrationContext.new(paths).migrations.map(&:version)
      end

      def applied_versions(connection)
        return [] unless connection.data_source_exists?('schema_migrations')

        connection.select_values('SELECT version FROM schema_migrations').map(&:to_i)
      end
    end
  end
end

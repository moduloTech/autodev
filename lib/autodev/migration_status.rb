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

    # Guards the per-process migration-file cache below. `pending` runs inside
    # `HealthReport#check_migrations`, i.e. inside a Puma request thread, and two
    # probes landing at once would otherwise write the memo Hash concurrently.
    FILE_SCAN_LOCK = Mutex.new

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

      # The log line a failed migration pass deserves, as [level, message] ready
      # for `Rails.logger.public_send`. Lives here rather than inline in the
      # initializer because the initializer is the one file in this change that no
      # test can execute: it returns early in `test`, and `development` /
      # `production` both point at the real ~/.autodev/autodev.db.
      #
      # Never raises. An exception escaping the initializer's rescue would abort
      # its loop with ActiveRecord::Base still pointed at the queue pool — a far
      # worse outcome than a vague log line.
      def failure_report(db_config, error)
        summary = "[auto_migrate] #{db_config.name} migration failed: #{error.class}: #{error.message}"
        return [:warn, "#{summary} — expected when two processes boot at once; the winner applied it"] if
          benign_race?(error)

        [:error, "#{summary} — #{outcome(db_config)}"]
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

      # What the failure actually cost, read from `schema_migrations` rather than
      # guessed from the exception: a pass can fail and still leave a complete
      # schema (a peer applied it), and saying so is worth as much as naming a gap.
      def outcome(db_config)
        unapplied = pending[db_config.name]
        return 'the schema is complete nonetheless, nothing left unapplied' unless unapplied

        "INCOMPLETE SCHEMA, unapplied: #{unapplied.join(', ')}. Jobs will fail until this is resolved; " \
          'see the migrations card on /admin/health.'
      end

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
      #
      # Memoised for the life of the process (Autodev #60). Half of `pending` has
      # to be re-read on every call — `schema_migrations` is the side that
      # changes — but this half is a walk of `db/migrate` / `db/queue_migrate`,
      # and those files are baked into the release tarball: they cannot appear or
      # disappear while autodev runs. `pending` sits behind
      # `HealthReport#check_migrations`, so without the memo an external probe
      # bought one directory traversal per database per request on an endpoint
      # whose whole point is being called often.
      #
      # Keyed on the resolved paths rather than the database name so a config
      # that repoints `migrations_paths` is not served another database's answer.
      def migration_versions(db_config)
        paths = migration_paths(db_config)
        FILE_SCAN_LOCK.synchronize do
          @migration_versions ||= {}
          @migration_versions[paths] ||= ::ActiveRecord::MigrationContext.new(paths).migrations.map(&:version)
        end
      end

      def migration_paths(db_config)
        Array(db_config.migrations_paths || 'db/migrate').map { |path| ::Rails.root.join(path).to_s }
      end

      def applied_versions(connection)
        return [] unless connection.data_source_exists?('schema_migrations')

        connection.select_values('SELECT version FROM schema_migrations').map(&:to_i)
      end
    end
  end
end

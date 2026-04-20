# frozen_string_literal: true

# SQLite persistence layer with Sequel ORM and AASM state machine for issues.
module Database
  @db = nil

  BUSY_TIMEOUT_MS = 30_000

  def self.connect(url)
    return unless url

    @db = open_connection(url)
    setup_sqlite!(url)
    migrate!
    migrate_statuses!
    true
  rescue Sequel::DatabaseConnectionError, Sequel::DatabaseError => e
    warn "  Database connection failed: #{e.message}"
    @db = nil
    false
  end

  def self.setup_sqlite!(url)
    return unless sqlite_url?(url)

    configure_sqlite_pragmas!
    log_sqlite_pragmas
  end

  def self.connected?
    !@db.nil?
  end

  def self.disconnect
    @db&.disconnect
    @db = nil
  end

  def self.db
    @db
  end

  # -- Build Issue Sequel::Model with AASM --

  def self.build_model!
    # Name the class BEFORE including AASM. AASM's StateMachineStore keys by
    # klass.to_s — if the class is anonymous at registration time, the key is
    # "#<Class:0x...>" but lookups after const_set use "Issue", causing a mismatch.
    klass = Class.new(Sequel::Model(db[:issues]))
    Object.const_set(:Issue, klass)
    klass.include(IssueBehavior)
  end

  # -- Startup recovery --

  def self.recover_on_startup!(max_retries:)
    return 0 unless connected?

    Recovery.run(db, max_retries)
  end

  # Single-connection pool. SQLite serializes writes at the file level, so
  # multiple pooled connections only add contention (and trigger
  # SQLite3::BusyException when writers collide). With max_connections: 1,
  # Sequel's ThreadedConnectionPool serializes all access through a Ruby
  # mutex, which is strictly faster than the SQLite lock dance for a
  # workload like ours (small, fast statements; no long transactions).
  # This is also why we don't need Sequel's `after_connect` here — PRAGMAs
  # set via `@db.run` apply to the only connection that ever exists.
  def self.open_connection(url)
    if url == 'sqlite://:memory:'
      Sequel.sqlite(max_connections: 1)
    elsif url.start_with?('sqlite://')
      db_path = File.expand_path(url.sub('sqlite://', ''))
      FileUtils.mkdir_p(File.dirname(db_path))
      Sequel.connect("sqlite://#{db_path}", max_connections: 1)
    else
      Sequel.connect(url)
    end
  end

  def self.configure_sqlite_pragmas!
    @db.run('PRAGMA journal_mode=WAL')
    @db.run("PRAGMA busy_timeout=#{BUSY_TIMEOUT_MS}")
  end

  def self.log_sqlite_pragmas
    journal_mode = scalar_pragma('journal_mode')
    busy_timeout = scalar_pragma('busy_timeout')
    warn "  Database pragmas: journal_mode=#{journal_mode}, busy_timeout=#{busy_timeout}ms, max_connections=1"
  rescue StandardError
    # best-effort diagnostic — never fail startup on this
  end

  def self.scalar_pragma(name)
    row = @db["PRAGMA #{name}"].first
    row.is_a?(Hash) ? row.values.first : row
  end

  def self.sqlite_url?(url)
    url.is_a?(String) && url.start_with?('sqlite://')
  end

  def self.migrate!
    Migration.run(@db)
  end

  def self.migrate_statuses!
    Migration.migrate_statuses!(@db)
  end

  private_class_method :open_connection, :setup_sqlite!, :configure_sqlite_pragmas!,
                       :log_sqlite_pragmas, :scalar_pragma, :sqlite_url?, :migrate!
end

require_relative 'database/migration'
require_relative 'database/recovery'

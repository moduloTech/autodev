# frozen_string_literal: true

# SQLite persistence layer with Sequel ORM and AASM state machine for issues.
module Database
  @db = nil

  def self.connect(url)
    return unless url

    @db = open_connection(url)
    migrate!
    migrate_statuses!
    true
  rescue Sequel::DatabaseConnectionError, Sequel::DatabaseError => e
    warn "  Database connection failed: #{e.message}"
    @db = nil
    false
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

  def self.open_connection(url)
    if url == 'sqlite://:memory:'
      Sequel.sqlite(max_connections: 5, after_connect: sqlite_after_connect)
    elsif url.start_with?('sqlite://')
      db_path = File.expand_path(url.sub('sqlite://', ''))
      FileUtils.mkdir_p(File.dirname(db_path))
      Sequel.connect("sqlite://#{db_path}", max_connections: 5, after_connect: sqlite_after_connect)
    else
      Sequel.connect(url, max_connections: 5)
    end
  end

  # Applied to every pooled connection. `busy_timeout` is per-connection in
  # SQLite, so setting it once on the pool is not enough — without this, only
  # the first connection waits on the writer lock and the rest raise
  # SQLite3::BusyException immediately under worker contention.
  def self.sqlite_after_connect
    lambda do |conn|
      conn.execute('PRAGMA journal_mode=WAL')
      conn.execute('PRAGMA busy_timeout=5000')
    end
  end

  def self.migrate!
    Migration.run(@db)
  end

  def self.migrate_statuses!
    Migration.migrate_statuses!(@db)
  end

  private_class_method :open_connection, :sqlite_after_connect, :migrate!
end

require_relative 'database/migration'
require_relative 'database/recovery'

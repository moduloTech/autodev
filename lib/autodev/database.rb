# frozen_string_literal: true

# SQLite persistence layer with Sequel ORM and AASM state machine for issues.
module Database
  @db = nil

  def self.connect(url)
    return unless url

    @db = open_connection(url)
    configure_pragmas!
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
      Sequel.sqlite(max_connections: 5)
    elsif url.start_with?('sqlite://')
      db_path = File.expand_path(url.sub('sqlite://', ''))
      FileUtils.mkdir_p(File.dirname(db_path))
      Sequel.connect("sqlite://#{db_path}", max_connections: 5)
    else
      Sequel.connect(url, max_connections: 5)
    end
  end

  def self.configure_pragmas!
    @db.run('PRAGMA journal_mode=WAL')
    @db.run('PRAGMA busy_timeout=5000')
  end

  def self.migrate!
    Migration.run(@db)
  end

  def self.migrate_statuses!
    Migration.migrate_statuses!(@db)
  end

  private_class_method :open_connection, :configure_pragmas!, :migrate!
end

require_relative 'database/migration'
require_relative 'database/recovery'

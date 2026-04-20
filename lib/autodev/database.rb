# frozen_string_literal: true

# SQLite persistence layer with Sequel ORM and AASM state machine for issues.
module Database
  @db = nil

  BUSY_TIMEOUT_MS = 30_000

  def self.connect(url)
    return unless url

    @db = open_connection(url)
    migrate!
    migrate_statuses!
    log_sqlite_pragmas if sqlite_url?(url)
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
  # SQLite3::BusyException immediately under worker contention. The Ruby
  # `busy_handler` is a defense-in-depth net in case the PRAGMA is silently
  # ignored or exceeded: it retries for up to ~BUSY_TIMEOUT_MS before giving up.
  def self.sqlite_after_connect
    lambda do |conn|
      conn.execute('PRAGMA journal_mode=WAL')
      conn.execute("PRAGMA busy_timeout=#{BUSY_TIMEOUT_MS}")
      install_busy_handler(conn)
    end
  end

  BUSY_DUMP_AFTER = 20

  def self.install_busy_handler(conn)
    deadline_s = BUSY_TIMEOUT_MS / 1000.0
    state = { dumped: false }
    conn.busy_handler { |count| handle_busy(count, deadline_s, state) }
  rescue NoMethodError
    # sqlite3 gem without busy_handler support — PRAGMA busy_timeout still applies.
  end

  def self.handle_busy(count, deadline_s, state)
    sleep_s = [0.05 * (count + 1), 0.5].min
    state[:dumped] = false if count.zero?
    if count == BUSY_DUMP_AFTER && !state[:dumped]
      state[:dumped] = true
      dump_thread_state(count)
    end
    return 0 if (count * sleep_s) >= deadline_s

    sleep(sleep_s)
    1
  end

  # Dumps backtraces of all threads to stderr when the busy_handler has
  # retried enough times to suggest real contention. Runs in the thread
  # that is waiting for the lock, so it sees the other threads holding it.
  def self.dump_thread_state(count)
    lines = ["[DB-LOCK] busy_handler waiting on SQLite lock (retry ##{count}). Thread states:"]
    Thread.list.each { |t| append_thread_lines(lines, t) }
    warn(lines.join("\n"))
  rescue StandardError => e
    warn "[DB-LOCK] failed to dump thread state: #{e.class}: #{e.message}"
  end

  def self.append_thread_lines(lines, thread)
    lines << "  Thread #{thread.object_id} status=#{thread.status} name=#{thread.name.inspect}"
    (thread.backtrace || []).first(30).each { |line| lines << "    #{line}" }
  end

  def self.log_sqlite_pragmas
    row = @db['PRAGMA busy_timeout'].first
    effective = row.is_a?(Hash) ? row.values.first : row
    warn "  Database pragmas: journal_mode=WAL, busy_timeout=#{effective}ms"
  rescue StandardError
    # best-effort diagnostic — never fail startup on this
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

  private_class_method :open_connection, :sqlite_after_connect, :install_busy_handler,
                       :handle_busy, :dump_thread_state, :append_thread_lines,
                       :log_sqlite_pragmas, :sqlite_url?, :migrate!
end

require_relative 'database/migration'
require_relative 'database/recovery'

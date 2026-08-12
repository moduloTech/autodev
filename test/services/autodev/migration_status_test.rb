# frozen_string_literal: true

require_relative '../../rails_helper'

# Autodev::MigrationStatus — the two questions config/initializers/auto_migrate.rb
# used to conflate into one `rescue StandardError` (Autodev #55).
#
# Q1 `benign_race?` is a heuristic over the exception message. It only ever picks
# a log level, so it is deliberately generous towards "benign" — getting it wrong
# costs one line written at the wrong severity and nothing else.
#
# Q2 `pending` / `incomplete_schema_report` is a set difference between the
# migration files on disk and the versions recorded in `schema_migrations`. It is
# the only predicate that gates anything (bin/autodev refuses to spawn the
# supervisor's children on a non-empty answer), which is why it must be exact
# rather than inferred from whatever exception the pass happened to raise.
class MigrationStatusTest < ActiveSupport::TestCase # rubocop:disable Metrics/ClassLength
  # --- Q1: benign boot race ------------------------------------------------

  # Two Rails apps boot back to back against the same SQLite file and SQLite
  # grants no advisory lock, so the loser of the race hits one of these. In every
  # case the column/table exists, because the winner created it.

  test 'a duplicate column name is a benign race' do
    error = ActiveRecord::StatementInvalid.new(
      'SQLite3::SQLException: duplicate column name: mr_review_timeout'
    )

    assert Autodev::MigrationStatus.benign_race?(error)
  end

  # ActiveRecord::StatementInvalid wraps the adapter exception, and depending on
  # the adapter path the SQLite text can sit on the cause rather than the message.
  test 'a duplicate column name carried only by the cause is a benign race' do
    error = begin
      begin
        raise SQLite3::SQLException, 'duplicate column name: mr_review_timeout'
      rescue StandardError
        raise ActiveRecord::StatementInvalid, 'An error occurred while executing the query'
      end
    rescue StandardError => e
      e
    end

    assert Autodev::MigrationStatus.benign_race?(error)
  end

  test 'a UNIQUE violation on schema_migrations is a benign race' do
    error = ActiveRecord::RecordNotUnique.new(
      'SQLite3::ConstraintException: UNIQUE constraint failed: schema_migrations.version'
    )

    assert Autodev::MigrationStatus.benign_race?(error)
  end

  test 'an already-existing table is a benign race' do
    error = ActiveRecord::StatementInvalid.new('SQLite3::SQLException: table "projects" already exists')

    assert Autodev::MigrationStatus.benign_race?(error)
  end

  test 'a concurrent migration is a benign race' do
    assert Autodev::MigrationStatus.benign_race?(ActiveRecord::ConcurrentMigrationError.new)
  end

  # --- Q1: everything else -------------------------------------------------

  # The motivating case: busy_timeout exhausted by an external writer. The ALTER
  # fails in *every* process, so nobody created the column.
  test 'a locked database is not a benign race' do
    error = ActiveRecord::StatementInvalid.new('SQLite3::BusyException: database is locked')

    assert_not Autodev::MigrationStatus.benign_race?(error)
  end

  test 'a missing table is not a benign race' do
    error = ActiveRecord::StatementInvalid.new('SQLite3::SQLException: no such table: projects')

    assert_not Autodev::MigrationStatus.benign_race?(error)
  end

  test 'an unrecognised error is not a benign race' do
    assert_not Autodev::MigrationStatus.benign_race?(RuntimeError.new('boom'))
  end

  # --- Q2: pending versions ------------------------------------------------

  def primary_config
    ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).find { |c| c.name == 'primary' }
  end

  def applied_versions
    ActiveRecord::Base.connection.select_values('SELECT version FROM schema_migrations').map(&:to_i)
  end

  # The assertion that says the gate does not trip in the normal case: this suite
  # runs against a fully migrated primary (test/rails_helper.rb migrates it).
  test 'nothing is pending on a fully migrated database' do
    assert_empty Autodev::MigrationStatus.pending_versions(primary_config)
  end

  test 'a version missing from schema_migrations is reported as pending' do
    version = applied_versions.max
    ActiveRecord::Base.connection.execute("DELETE FROM schema_migrations WHERE version = '#{version}'")

    assert_equal [version], Autodev::MigrationStatus.pending_versions(primary_config)
  ensure
    ActiveRecord::Base.connection.execute("INSERT INTO schema_migrations (version) VALUES ('#{version}')")
  end

  test 'the same version stops being pending once recorded again' do
    version = applied_versions.max
    ActiveRecord::Base.connection.execute("DELETE FROM schema_migrations WHERE version = '#{version}'")
    ActiveRecord::Base.connection.execute("INSERT INTO schema_migrations (version) VALUES ('#{version}')")

    assert_empty Autodev::MigrationStatus.pending_versions(primary_config)
  end

  # A rollback to an earlier autodev leaves versions in the DB that have no file.
  # The difference is computed one way only, so that reads as complete, not broken.
  test 'a version recorded with no migration file is not pending' do
    ActiveRecord::Base.connection.execute("INSERT INTO schema_migrations (version) VALUES ('29999999999999')")

    assert_empty Autodev::MigrationStatus.pending_versions(primary_config)
  ensure
    ActiveRecord::Base.connection.execute("DELETE FROM schema_migrations WHERE version = '29999999999999'")
  end

  # --- Q2: the file scan is paid once per process (Autodev #60) -------------
  #
  # `pending` backs HealthReport#check_migrations, i.e. every single /healthz
  # hit. The `schema_migrations` half has to be re-read each time — that is the
  # answer that changes — but the migration *files* cannot appear or disappear
  # during the life of the process, and walking `db/migrate` + `db/queue_migrate`
  # per request is a directory traversal an aggressive external probe should not
  # be able to buy.

  test 'the migration files are scanned once, not on every pending call' do
    Autodev::MigrationStatus.pending # warm the per-process cache
    scans = 0
    real = ActiveRecord::MigrationContext.method(:new)
    counting = lambda do |paths|
      scans += 1
      real.call(paths)
    end

    ActiveRecord::MigrationContext.stub(:new, counting) do
      Autodev::MigrationStatus.pending
      Autodev::MigrationStatus.pending
    end

    assert_equal 0, scans
  end

  # Memoising the file list must not memoise the answer: `schema_migrations` is
  # exactly what changes while the process runs (the initializer's pass, a hand
  # `bin/rails db:migrate`), and a cached verdict would keep /healthz red — or,
  # worse, green — after the fact.
  test 'a version deleted from schema_migrations is still seen after the cache is warm' do
    Autodev::MigrationStatus.pending
    version = applied_versions.max
    ActiveRecord::Base.connection.execute("DELETE FROM schema_migrations WHERE version = '#{version}'")

    assert_equal [version], Autodev::MigrationStatus.pending_versions(primary_config)
  ensure
    ActiveRecord::Base.connection.execute("INSERT INTO schema_migrations (version) VALUES ('#{version}')")
  end

  # --- The log line the initializer prints ---------------------------------
  #
  # config/initializers/auto_migrate.rb is the one file in this change no test can
  # execute — it returns early in `test`, and development / production point at
  # the real ~/.autodev/autodev.db. So everything but its two-line rescue body
  # lives here and is pinned here.

  test 'a benign race is reported as a warning' do
    error = ActiveRecord::StatementInvalid.new('SQLite3::SQLException: duplicate column name: x')

    level, message = Autodev::MigrationStatus.failure_report(primary_config, error)

    assert_equal :warn, level
    assert_includes message, '[auto_migrate] primary migration failed'
    assert_includes message, 'the winner applied it'
  end

  test 'anything else is reported as an error naming what is unapplied' do
    version = applied_versions.max
    ActiveRecord::Base.connection.execute("DELETE FROM schema_migrations WHERE version = '#{version}'")
    error = ActiveRecord::StatementInvalid.new('SQLite3::BusyException: database is locked')

    level, message = Autodev::MigrationStatus.failure_report(primary_config, error)

    assert_equal :error, level
    assert_match(%r{INCOMPLETE SCHEMA, unapplied: #{version}\b.*/admin/health}, message)
  ensure
    ActiveRecord::Base.connection.execute("INSERT INTO schema_migrations (version) VALUES ('#{version}')")
  end

  # A pass can fail and still leave a complete schema — the peer that won the race
  # applied it. Saying so is worth as much as naming a gap.
  test 'an unclassified failure that left nothing unapplied says so' do
    error = ActiveRecord::StatementInvalid.new('SQLite3::BusyException: database is locked')

    Autodev::MigrationStatus.stub(:pending, {}) do
      level, message = Autodev::MigrationStatus.failure_report(primary_config, error)

      assert_equal :error, level
      assert_includes message, 'complete nonetheless'
    end
  end

  # --- Q2: the abort message ----------------------------------------------

  test 'no report when every migration is applied' do
    Autodev::MigrationStatus.stub(:pending, {}) do
      assert_nil Autodev::MigrationStatus.incomplete_schema_report
    end
  end

  test 'the report names the database and the unapplied versions' do
    Autodev::MigrationStatus.stub(:pending, { 'primary' => [20_260_810_000_001] }) do
      report = Autodev::MigrationStatus.incomplete_schema_report

      assert_includes report, 'primary'
      assert_includes report, '20260810000001'
    end
  end
end

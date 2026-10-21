# frozen_string_literal: true

# Points Solid Queue at a throwaway SQLite file carrying its schema, for the
# tests that need its tables (Autodev #139). The test environment's `queue`
# database is `:memory:`: it holds no Solid Queue table, and every pooled
# connection — a worker thread's included — would see a different, empty one.
module QueueDatabaseOnFile
  def use_queue_database_on_file
    @queue_dir = Dir.mktmpdir('autodev-queue')
    @previous_queue_config = SolidQueue::Record.connection_db_config
    SolidQueue::Record.establish_connection(
      adapter: 'sqlite3', database: File.join(@queue_dir, 'queue.sqlite3'), pool: 20, timeout: 30_000
    )
    load_queue_schema
    warm_model_schemas
  end

  def restore_queue_database
    # Only this pool: the handler is shared, and clearing all of it would drop
    # the `:memory:` primary database every later test reads.
    SolidQueue::Record.connection_pool.disconnect!
    SolidQueue::Record.establish_connection(@previous_queue_config)
    solid_queue_models.each(&:reset_column_information)
    FileUtils.rm_rf(@queue_dir)
  end

  private

  def load_queue_schema
    ActiveRecord::Migration.verbose = false
    require Rails.root.join('db/queue_migrate/20260608000001_create_solid_queue_tables.rb').to_s
    SolidQueue::Record.connection_pool.with_connection do |connection|
      CreateSolidQueueTables.new.exec_migration(connection, :up)
    end
  end

  # Two workers in one process load the models' columns lazily, each inside
  # its claim transaction: one holds SQLite's write lock waiting for the
  # schema monitor, the other holds the monitor waiting for the lock, until the
  # 30 s busy timeout. In production each worker is a process of its own and
  # never meets the other's monitor; here the columns are read up front.
  def warm_model_schemas
    solid_queue_models.each do |model|
      model.reset_column_information
      model.load_schema
    end
  end

  def solid_queue_models
    Rails.autoloaders.main.eager_load_namespace(SolidQueue)
    SolidQueue::Record.descendants.reject(&:abstract_class?)
  end
end

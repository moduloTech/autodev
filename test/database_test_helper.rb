# frozen_string_literal: true

# Helper to run database tests with an in-memory SQLite instance.
# Connects, migrates, builds the Issue model, yields, then tears down.
module DatabaseTestHelper
  @db_initialized = false
  @iid_counter = 0

  # Ordered happy-path transitions: [target_state, event_to_fire]
  HAPPY_PATH = [
    ['cloning',            :start_processing!],
    ['checking_spec',      :clone_complete!],
    ['implementing',       :spec_clear!],
    ['committing',         :impl_complete!],
    ['pushing',            :commit_complete!],
    ['creating_mr',        :push_complete!],
    ['checking_pipeline',  :mr_created!]
  ].freeze

  class << self
    attr_accessor :db_initialized, :iid_counter
  end

  def setup_database
    # In-memory SQLite is per-connection, so any reconnect drops the
    # schema the test_helper.rb migration created. Re-run the migration
    # idempotently (every `create_table` is `if_not_exists: true`) and
    # wipe the two tables each test writes to.
    primary = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env)
                                .find { |c| c.name == 'primary' }
    ActiveRecord::Base.establish_connection(primary)
    paths = Array(primary.migrations_paths || 'db/migrate').map { |p| Rails.root.join(p).to_s }
    ActiveRecord::MigrationContext.new(paths).migrate
    wipe_business_tables
  end

  # Wipe the tables these (non-transactional) tests write to. Called at setup
  # AND at teardown: because Minitest::Test tests don't run inside a rolled-back
  # transaction like ActiveSupport::TestCase, a test that leaves rows behind
  # (e.g. an issue in `status: 'error'`) pollutes whatever runs next. Cleaning
  # up at setup only protected each test from its predecessors; wiping at
  # teardown too stops it leaking into successors — including transactional
  # tests that read global issue state (e.g. HealthReport's issues_error check),
  # which otherwise flaked depending on Minitest's run order. See task #25.
  def wipe_business_tables
    %w[audit_logs activity_events issues].each do |table|
      ActiveRecord::Base.connection.execute("DELETE FROM #{table}")
    end
  rescue ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished
    nil # table/connection not present in this test's context — nothing to clean
  end

  # Minitest lifecycle hook (chains via super); runs after every test that
  # includes this module, so the wipe above happens whether or not the test
  # defines its own teardown.
  def after_teardown
    super
    wipe_business_tables
  end

  def create_issue(overrides = {})
    DatabaseTestHelper.iid_counter += 1
    defaults = { project_path: 'group/project', issue_iid: DatabaseTestHelper.iid_counter, status: 'pending' }
    Issue.create!(defaults.merge(overrides))
  end

  # Advance an issue through the happy path up to a target state.
  def advance_to(issue, target_state)
    HAPPY_PATH.each do |state, event|
      issue.send(event)
      break if state == target_state
    end
  end
end

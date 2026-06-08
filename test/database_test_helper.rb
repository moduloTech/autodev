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

  def setup_database # rubocop:disable Metrics/AbcSize
    # In-memory SQLite is per-connection, so any reconnect drops the
    # schema the test_helper.rb migration created. Re-run the migration
    # idempotently (every `create_table` is `if_not_exists: true`) and
    # wipe the two tables each test writes to.
    primary = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env)
                                .find { |c| c.name == 'primary' }
    ActiveRecord::Base.establish_connection(primary)
    paths = Array(primary.migrations_paths || 'db/migrate').map { |p| Rails.root.join(p).to_s }
    ActiveRecord::MigrationContext.new(paths).migrate
    ActiveRecord::Base.connection.execute('DELETE FROM activity_events')
    ActiveRecord::Base.connection.execute('DELETE FROM issues')
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

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
    unless DatabaseTestHelper.db_initialized
      Database.connect('sqlite://:memory:')
      Database.build_model!
      DatabaseTestHelper.db_initialized = true
    end
    Database.db[:issues].delete
  end

  def create_issue(overrides = {})
    DatabaseTestHelper.iid_counter += 1
    defaults = { project_path: 'group/project', issue_iid: DatabaseTestHelper.iid_counter, status: 'pending' }
    Issue.create(defaults.merge(overrides))
  end

  # Advance an issue through the happy path up to a target state.
  def advance_to(issue, target_state)
    HAPPY_PATH.each do |state, event|
      issue.send(event)
      break if state == target_state
    end
  end
end

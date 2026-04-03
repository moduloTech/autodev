# frozen_string_literal: true

# Helper to run database tests with an in-memory SQLite instance.
# Connects, migrates, builds the Issue model, yields, then tears down.
module DatabaseTestHelper
  @db_initialized = false
  @iid_counter = 0

  class << self
    attr_accessor :db_initialized, :iid_counter
  end

  def setup_database
    unless DatabaseTestHelper.db_initialized
      Database.connect('sqlite://:memory:')
      Database.build_model!
      DatabaseTestHelper.db_initialized = true
    end
    # Clean slate for each test
    Database.db[:issues].delete
  end

  def create_issue(overrides = {})
    DatabaseTestHelper.iid_counter += 1
    defaults = { project_path: 'group/project', issue_iid: DatabaseTestHelper.iid_counter, status: 'pending' }
    Issue.create(defaults.merge(overrides))
  end

  # Advance an issue through the happy path up to a target state.
  def advance_to(issue, target_state)
    transitions = {
      'cloning' => -> { issue.start_processing! },
      'checking_spec' => lambda {
        advance_to(issue, 'cloning')
        issue.clone_complete!
      },
      'implementing' => lambda {
        advance_to(issue, 'checking_spec')
        issue.spec_clear!
      },
      'committing' => lambda {
        advance_to(issue, 'implementing')
        issue.impl_complete!
      },
      'pushing' => lambda {
        advance_to(issue, 'committing')
        issue.commit_complete!
      },
      'creating_mr' => lambda {
        advance_to(issue, 'pushing')
        issue.push_complete!
      },
      'reviewing' => lambda {
        advance_to(issue, 'creating_mr')
        issue.mr_created!
      },
      'checking_pipeline' => lambda {
        advance_to(issue, 'reviewing')
        issue.review_complete!
      }
    }
    transitions[target_state]&.call
  end
end

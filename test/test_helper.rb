# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "tmpdir"
require "json"
require "yaml"
require "sequel"
require "aasm"
require "i18n"

I18n.available_locales = [:en]
I18n.default_locale = :en

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "autodev/errors"
require "autodev/logger"
require "autodev/config"
require "autodev/language_detector"
require "autodev/locales"
require "autodev/shell_helpers"
require "autodev/database"

# Minimal Pastel stand-in that returns messages unchanged.
class FakePastel
  %i[red yellow cyan dim green magenta white bold].each do |color|
    define_method(color) { |msg| msg }
  end
end

# Helper to run database tests with an in-memory SQLite instance.
# Connects, migrates, builds the Issue model, yields, then tears down.
module DatabaseTestHelper
  @@db_initialized = false
  @@iid_counter = 0

  def setup_database
    unless @@db_initialized
      Database.connect("sqlite://:memory:")
      Database.build_model!
      @@db_initialized = true
    end
    # Clean slate for each test
    Database.db[:issues].delete
  end

  def create_issue(overrides = {})
    @@iid_counter += 1
    defaults = { project_path: "group/project", issue_iid: @@iid_counter, status: "pending" }
    Issue.create(defaults.merge(overrides))
  end

  # Advance an issue through the happy path up to a target state.
  def advance_to(issue, target_state)
    transitions = {
      "cloning"             => -> { issue.start_processing! },
      "checking_spec"       => -> { advance_to(issue, "cloning"); issue.clone_complete! },
      "implementing"        => -> { advance_to(issue, "checking_spec"); issue.spec_clear! },
      "committing"          => -> { advance_to(issue, "implementing"); issue.impl_complete! },
      "pushing"             => -> { advance_to(issue, "committing"); issue.commit_complete! },
      "creating_mr"         => -> { advance_to(issue, "pushing"); issue.push_complete! },
      "reviewing"           => -> { advance_to(issue, "creating_mr"); issue.mr_created! },
      "checking_pipeline"   => -> { advance_to(issue, "reviewing"); issue.review_complete! },
    }
    transitions[target_state]&.call
  end
end

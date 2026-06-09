# frozen_string_literal: true

# Boot Rails for ActiveRecord model tests.
#
# This is separate from `test/test_helper.rb` (the Sequel-side helper) because
# the bulk of the suite tests the legacy Sinatra+Sequel code path. Loading
# Rails into those test files would force-load ActiveRecord, AASM-on-AR
# adapters, etc., for no gain.
#
# AUTODEV_SKIP_LEGACY=1 short-circuits config/initializers/legacy_sinatra.rb
# so `Object.const_set(:Issue, ...)` (the Sequel side) does NOT fire — which
# means AR tests live in a pure-Rails world with the Issue / ActivityEvent
# constants undefined. That is fine for step-2 models (User, Project,
# ProjectAppCommand, ProjectMembership); when Issue moves to AR in phase C,
# the legacy initializer + this guard come down together.

ENV['RAILS_ENV'] ||= 'test'
ENV['AUTODEV_SKIP_LEGACY'] = '1'

require_relative '../config/environment'

require 'minitest/autorun'
require 'active_support/test_case'

# Force routes to load so `devise_for :users` registers `Devise.mappings[:user]`
# before any `Devise::Test::IntegrationHelpers#sign_in` call. Without this,
# the integration tests for the admin / issues controllers occasionally
# raise "Could not find a valid mapping for #<User ...>" when the test file
# order causes `sign_in` to run before the routes block has been touched
# (Devise populates mappings as a side-effect of `Rails.application.routes`).
Rails.application.reload_routes!

# Run all pending migrations against the (in-memory by default) test DB,
# once per process. Idempotent — re-running with everything already migrated
# is a no-op.
ActiveRecord::Base.establish_connection
ActiveRecord::MigrationContext.new(Rails.root.join('db/migrate').to_s).migrate

# Plain `rake test` doesn't go through the active_record railtie's test_help,
# and `ActiveRecord::TestFixtures` has a Zeitwerk-circular load when required
# from this position. Cheaper to just wipe tables between tests — SQLite
# `:memory:` makes DELETE essentially free. AR models added in step 2 only.
module ActiveRecordTestCleanup
  TABLES = %w[audit_logs activity_events issues project_memberships
              project_app_commands projects users].freeze

  def teardown
    super
    TABLES.each { |t| ActiveRecord::Base.connection.execute("DELETE FROM #{t}") }
  end
end
ActiveSupport::TestCase.include(ActiveRecordTestCleanup)

# frozen_string_literal: true

# Boot Rails for ActiveRecord model tests.
#
# This is separate from `test/test_helper.rb` (the Sequel-side helper) because
# the bulk of the suite tests the legacy Sinatra+Sequel code path. Loading
# Rails into those test files would force-load ActiveRecord, AASM-on-AR
# adapters, etc., for no gain.
#
# AUTODEV_SKIP_LEGACY=1 keeps config/initializers/load_autodev_config.rb from
# reading the developer's real `~/.autodev/config.yml` into `Web.config` — a real
# GitLab token, a real project list, and a `ConfigError` when the file is absent.
# That is all the flag does. It deliberately no longer skips the initializer's
# `require_relative '../../lib/autodev'`, which is the only thing that defines
# the `lib/` constants `app/` reaches for (`Locales`, `GitlabHelpers`, `Redactor`,
# `NumericSettings`, `Config`, `PipelineMonitor`, …) — `lib/` is off the Zeitwerk
# autoload path. This file used to carry nine ad-hoc `require`s for that reason,
# added one at a time as each new test file tripped over the gap; the whole tree
# now loads once, at boot, for every environment (Autodev #64). Nothing has to be
# added here when a test needs a `lib/` constant. `test/rails_lib_loading_test.rb`
# is the guard.

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
  # Child-before-parent order so SQLite FK enforcement (default-on under
  # AR 8) does not reject the DELETE chain. ActiveStorage tables are
  # listed first because they reference each other (variants → blobs);
  # the autospec_* set sits below ActiveStorage because attachments
  # connect a draft row to a blob row, and approvals + messages +
  # attachments all FK to drafts.
  TABLES = %w[
    active_storage_variant_records
    active_storage_attachments
    active_storage_blobs
    autospec_approvals
    autospec_attachments
    autospec_messages
    autospec_drafts
    audit_logs
    activity_events
    gitlab_request_stats
    gitlab_transport_failures
    issues
    project_memberships
    project_app_commands
    project_ticket_templates
    projects
    users
  ].freeze

  def teardown
    super
    TABLES.each { |t| ActiveRecord::Base.connection.execute("DELETE FROM #{t}") }
  end
end
ActiveSupport::TestCase.include(ActiveRecordTestCleanup)

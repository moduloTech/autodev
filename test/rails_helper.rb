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

# AUTODEV_SKIP_LEGACY=1 also short-circuits config/initializers/load_autodev_config.rb,
# which is what normally requires `lib/autodev` (and transitively `autodev/locales`).
# The web Phlex views call `t_web` → `Locales.t` whenever they render through
# the shared sidebar/topbar, so they crash with `NameError (uninitialized
# constant Web::I18nHelpers::Locales)` in the test environment unless we wire
# the dependency up by hand. Pull in only what the views need — not the full
# lib/autodev tree (which would drag in Sequel-era modules).
require 'autodev/locales'
# `NumericSettings` (lib/autodev) carries the type + range declaration every
# numeric per-project column is validated against (Autodev #58), so the Project
# model needs it defined — same AUTODEV_SKIP_LEGACY gap as the requires around it.
require 'autodev/numeric_settings'
require 'autodev/config'
# `Autodev::DeployReview` (app/services) calls `GitlabHelpers.field` /
# `.build_gitlab_client`, but GitlabHelpers lives in lib/autodev (required at
# boot via lib/autodev.rb, which AUTODEV_SKIP_LEGACY=1 skips). Without this
# require its unit test only passed by accident when another file had already
# loaded the constant — run in isolation every probe degraded to :error
# (NameError: uninitialized constant …::GitlabHelpers). Light dep (just 'time').
require 'autodev/gitlab_helpers'
# `Web::Helpers#screenshot_dir_for` (called by IssueShow's screenshots card)
# references top-level `ScreenshotUploader`, which lives under lib/autodev and
# is only pulled in by test_helper.rb's Sequel-side boot, not this one — same
# class of gap as GitlabHelpers above. Without this require, the first
# controller test to render a fully authenticated issue#show page run in
# isolation raises `NameError: uninitialized constant Web::Helpers::ScreenshotUploader`.
require 'autodev/screenshot_uploader'
# `IssueShow` scrubs the two captured streams and the raw-data JSON through
# top-level `Redactor` before rendering them (Autodev #59) — third instance of
# the same gap. In production `config/initializers/load_autodev_config.rb`
# requires `lib/autodev` at boot, which pulls it in; under AUTODEV_SKIP_LEGACY=1
# that initializer returns early, so a controller test rendering issue#show in
# isolation raised `NameError: uninitialized constant Web::Views::IssueShow::Redactor`
# (it only passed under `rake test` because another file's helper had loaded it).
require 'autodev/redactor'

# `ConfigValidator` and the error it raises — fourth instance of the same gap. It
# is the boot-time refusal for a bad numeric global, including the `monitoring:`
# block, so a test that exercises that refusal has to be able to name both under
# AUTODEV_SKIP_LEGACY=1.
require 'autodev/errors'
require 'autodev/errors/config_error'
require 'autodev/config_validator'

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

# frozen_string_literal: true

require 'minitest/autorun'
require 'fileutils'
require 'tmpdir'
require 'json'
require 'yaml'
require 'aasm'
require 'i18n'

I18n.available_locales = [:en]
I18n.default_locale = :en

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

# Step 2 second half: boot the Rails environment so AR `Issue` and
# `ActivityEvent` are defined for any test that touches the DB. We still
# want the Sinatra-stack stubs from stub_autodev.rb (Pastel + AppLogger
# stand-ins for the CLI tests), so we set AUTODEV_SKIP_LEGACY=1 to keep
# the legacy_sinatra initializer from re-requiring lib/autodev and
# pulling pastel back in under a different class definition.
ENV['RAILS_ENV'] ||= 'test'
ENV['AUTODEV_SKIP_AUTO_MIGRATE'] ||= '1'

require_relative 'stub_autodev'

require_relative '../config/environment'

# Force-load the AR models we care about. `Rails.application.eager_load!`
# would NameError on Devise::Mailer (action_mailer railtie is intentionally
# absent from this skeleton). Explicit requires are enough — every other
# model becomes available via the same Zeitwerk autoloader.
require_relative '../app/models/application_record'
require_relative '../app/models/issue'
require_relative '../app/models/activity_event'

# Run the AR migrations once per process against the in-memory test DBs.
ActiveRecord::Base.configurations.configs_for(env_name: Rails.env).each do |db_config|
  paths = Array(db_config.migrations_paths || 'db/migrate').map { |p| Rails.root.join(p).to_s }
  ActiveRecord::Base.establish_connection(db_config)
  ActiveRecord::MigrationContext.new(paths).migrate
end
primary = ActiveRecord::Base.configurations.configs_for(env_name: Rails.env)
                            .find { |c| c.name == 'primary' }
ActiveRecord::Base.establish_connection(primary)

require 'autodev/errors'
require 'autodev/logger'
require 'autodev/config_validator'
require 'autodev/project_validator'
require 'autodev/app_validator'
require 'autodev/app_instructions'
require 'autodev/screenshot_uploader'
require 'autodev/config'
require 'autodev/language_detector'
require 'autodev/locales'
require 'autodev/shell_helpers'

# Minimal Pastel stand-in that returns messages unchanged.
class FakePastel
  %i[red yellow cyan dim green magenta white bold].each do |color|
    define_method(color) { |msg| msg }
  end
end

require_relative 'stub_logger'
require_relative 'database_test_helper'

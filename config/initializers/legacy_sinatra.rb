# frozen_string_literal: true

# Phase B of the railsification: Rails mounts the existing Sinatra
# Web::Server at the catch-all route. While there is at most a handful of
# Rails-native routes (porting one-by-one in following commits), every
# request that does not match those falls through to Sinatra, which then
# answers it exactly the way bin/autodev's embedded web does today.
#
# This initializer wires the legacy Sequel + Sinatra side INTO the Rails
# process:
#   1. requires lib/autodev/* (so Web::Server is defined),
#   2. loads ~/.autodev/config.yml via Config.load,
#   3. opens the same SQLite database that bin/rails AR uses,
#   4. builds the dynamic Sequel models (Issue, ActivityEvent),
#   5. hands the config hash to Web::Server.
#
# The Sequel-side Database.build_model! does `Object.const_set(:Issue, ...)`.
# That is why the AR Issue / ActivityEvent mirrors added in phase A were
# removed in the same commit — both classes can't share the top-level
# constant. They will come back (and become authoritative) in phase C, once
# `lib/autodev/web/` is deleted and the poller has moved to Solid Queue.
#
# Set AUTODEV_SKIP_LEGACY=1 to skip this entire block — useful for tooling
# like `bin/rails db:migrate` or `bin/rails runner` snippets that should
# not touch the Sequel side.

return if ENV['AUTODEV_SKIP_LEGACY']

require_relative '../../lib/autodev'

Rails.application.config.after_initialize do
  config = Config.load({})

  # Allow `AUTODEV_DB=/tmp/x.db bin/rails server` to override BOTH sides
  # (AR via config/database.yml, Sequel via this initializer) and keep them
  # pointed at the same file during local testing.
  config['database_url'] = "sqlite://#{ENV['AUTODEV_DB']}" if ENV['AUTODEV_DB']

  unless Database.connect(config['database_url'])
    Rails.logger.warn("[legacy_sinatra] Database.connect failed for #{config['database_url']}; Sinatra routes will 500")
    next
  end

  Database.build_model!
  Web::Server.configure_with(config)
end

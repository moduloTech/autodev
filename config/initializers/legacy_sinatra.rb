# frozen_string_literal: true

# Legacy bridge between Rails and the remaining Sinatra-era code.
# What this still does, post-step-2-second-half (Sequel→AR cutover):
#   1. requires lib/autodev/* so `Web::Server` (Phlex helpers + EventBus)
#      and the worker classes (`IssueProcessor`, `MrFixer`, `PipelineMonitor`)
#      remain available to the Rails controllers and Solid Queue jobs.
#   2. loads `~/.autodev/config.yml` via `Config.load` and hands the result
#      to `Web::Server.configure_with` so the Phlex view layer can read
#      `web.locale` etc.
#
# What it no longer does:
#   - Opens a Sequel connection. `Issue` and `ActivityEvent` are now AR
#     models (cf. app/models/) and `ActiveRecord::Base` owns the SQLite
#     pool via `config/database.yml`. The old `Database.connect` /
#     `Database.build_model!` path is dead; `Object.const_set(:Issue, ...)`
#     would now collide with the AR model that lives at the same constant.
#
# Set AUTODEV_SKIP_LEGACY=1 to skip the whole block — useful for tests
# that don't want `lib/autodev` loaded at all (`test/jobs/*`).

return if ENV['AUTODEV_SKIP_LEGACY']

require_relative '../../lib/autodev'

Rails.application.config.after_initialize do
  config = Config.load({})
  Web::Server.configure_with(config)
end

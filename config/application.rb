# frozen_string_literal: true

require_relative 'boot'

# Rails skeleton — phase A of the railsification (cf. autodev/docs/autospec.md §D).
# Loaded only by bin/rails; bin/autodev (bundler/inline Sinatra) does not boot this.
# Only the frameworks we need are required — the rest (action_mailer, action_cable,
# active_storage, action_text, action_mailbox) will be enabled when they actually
# have a consumer. active_job came in with step 5 (Solid Queue backend).
require 'rails'
require 'active_model/railtie'
require 'active_record/railtie'
require 'active_job/railtie'
require 'action_controller/railtie'
require 'action_view/railtie'

# We intentionally skip `Bundler.require(*Rails.groups)` here so that
# Sequel/Sinatra/Phlex/Puma — loaded by bin/autodev via bundler/inline — are
# not double-loaded in the Rails process. Rails-only gems load via the
# explicit requires above; AR models pull in `sqlite3` directly.
require 'sqlite3'

# Step 3 of the railsification — Devise + omniauth. These must be required
# BEFORE the Application class is defined so Devise's engine and OmniAuth's
# strategies register with Rails::Engine.subclasses and Rails picks up their
# autoload paths (e.g. `devise/app/controllers/devise/*`). If we required
# them in `config/initializers/devise.rb` instead, the engine registration
# would happen too late and `Devise::OmniauthCallbacksController` wouldn't
# resolve at boot.
require 'devise'
require 'omniauth-entra-id'
require 'omniauth/rails_csrf_protection'

# Step 5 of the railsification — Solid Queue backs ActiveJob for the recurring
# poll job. Same Bundler.require-skipped story as Devise: the gem's engine
# must register BEFORE Application is defined so its autoloads + recurring
# task machinery are picked up by Rails::Engine.subclasses.
require 'solid_queue'

module Autodev
  # Rails application root — minimal railtie set, Bundler.require skipped.
  # See file header for the rationale; this class is mostly a configuration
  # surface so most of the interesting wiring lives in the initializers/.
  class Application < Rails::Application
    config.load_defaults 8.1

    # Phase A: Zeitwerk autoloads from app/* only. lib/ stays off the autoload
    # path so the legacy Sequel modules in lib/autodev (loaded by bin/autodev)
    # are never pulled into the Rails process. Rake tasks under lib/tasks/*.rake
    # still load via `Rails.application.load_tasks` — that is a separate
    # mechanism and does not require autoload.
    config.eager_load = false
    config.add_autoload_paths_to_load_path = false

    # Skip generator hooks for stacks we are not using yet.
    config.generators.system_tests = nil

    # Step 5: ActiveJob backend is Solid Queue. Solid Queue itself reads/writes
    # exclusively from the `queue` AR connection (see config/database.yml) so
    # the busy WAL on autodev_queue.db is isolated from the business writes
    # on autodev.db.
    config.active_job.queue_adapter = :solid_queue
    config.solid_queue.connects_to = { database: { writing: :queue } }
  end
end

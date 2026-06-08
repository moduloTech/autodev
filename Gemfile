# frozen_string_literal: true

source 'https://rubygems.org'

# Runtime dependencies. Until phase B of the railsification, bin/autodev
# (Sinatra+Sequel) and bin/rails (Rails) both load from this Gemfile.
gem 'aasm',    '~> 5.5'
gem 'gitlab',  '~> 5.1'
gem 'i18n',    '~> 1.0'
gem 'logger'
gem 'ostruct'
gem 'pastel', '~> 0.8'
gem 'phlex', '~> 2.4', '>= 2.4.1'
gem 'puma',   '~> 6.0'
gem 'rack',   '~> 3.0'
gem 'sequel', '~> 5.0'
gem 'sinatra', '~> 4.0'
gem 'sinatra-contrib', '~> 4.0'
gem 'sqlite3', '~> 2.0'

# Railsification — phase A: Rails loads its own AR models in parallel to Sequel.
# bin/autodev is still bundler/inline and does NOT require these.
gem 'rails', '~> 8.1.3'

# Railsification — step 3: Devise + omniauth Azure AD (Microsoft 365 SSO).
# `bin/autodev` (Sinatra-only entrypoint) never loads these — `lib/autodev.rb`
# doesn't `require 'devise'`. They are pulled in only by `bin/rails server`
# via the active_record / action_controller railties.
gem 'activerecord-session_store', '~> 2.1'
gem 'devise',                     '~> 4.9'
# `omniauth-entra-id` is the maintained successor of the deprecated
# `omniauth-azure-activedirectory-v2`. The OmniAuth strategy class name is
# `Strategies::EntraId`; provider symbol passed to Devise is `:entra_id`.
gem 'omniauth-entra-id', '~> 3.0'
# Protects the omniauth POST callback against CSRF — omniauth 2.x defaults
# to POST-only callbacks to prevent CSRF, and this middleware emits the
# matching authenticity token check.
gem 'omniauth-rails_csrf_protection', '~> 1.0'

# Railsification — step 5: Solid Queue for the recurring poll job. Same
# Bundler.require-skipped story as Devise — explicit require in
# config/application.rb is required for the engine to register its tables.
gem 'solid_queue', '~> 1.1'

# Test dependencies
gem 'minitest', '~> 5.0'
gem 'rack-test', '~> 2.1'
gem 'rake', '~> 13.0'

gem 'rubocop', '~> 1.86'

gem 'rubocop-minitest', '~> 0.39.1'
gem 'rubocop-rake', '~> 0.7.1'
gem 'rubocop-sequel', '~> 0.4.1'

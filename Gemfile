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

# Test dependencies
gem 'minitest', '~> 5.0'
gem 'rack-test', '~> 2.1'
gem 'rake', '~> 13.0'

gem 'rubocop', '~> 1.86'

gem 'rubocop-minitest', '~> 0.39.1'
gem 'rubocop-rake', '~> 0.7.1'
gem 'rubocop-sequel', '~> 0.4.1'

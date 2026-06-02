# frozen_string_literal: true

# This file is used by Rack-based servers to start the application.
# Phase A: not yet wired up — `bin/rails server` will work but serve nothing
# of interest. Phase B will mount Sinatra (Web::Server) as middleware here
# (cf. autodev/docs/autospec.md §D).

require_relative 'config/environment'

run Rails.application
Rails.application.load_server

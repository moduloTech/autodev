# frozen_string_literal: true

module SkillsInjector
  module Templates
    # Static text sections for the Rails conventions skill.
    module RailsSections
      DEVISE = <<~DEVISE
        ## Authentication (Devise)

        This project uses Devise. Do not reimplement authentication. Use the existing Devise setup:
        `current_user`, `authenticate_user!`, `user_signed_in?`.
      DEVISE

      PUNDIT = <<~PUNDIT
        ## Authorization (Pundit)

        This project uses Pundit. Add policy classes in `app/policies/`. Call `authorize @record`
        in controllers. Use `policy_scope` for index queries.
      PUNDIT

      CANCANCAN = <<~CAN
        ## Authorization (CanCanCan)

        This project uses CanCanCan. Define abilities in `app/models/ability.rb`.
        Use `authorize!` or `load_and_authorize_resource` in controllers.
      CAN

      SIDEKIQ = {
        'direct' => <<~SQ,
          ## Background Jobs (Sidekiq direct)

          This project uses Sidekiq directly (not via ActiveJob). Jobs live in `app/workers/`.
          - Include `Sidekiq::Worker` (or `Sidekiq::Job` in Sidekiq 7+).
          - Enqueue with `MyWorker.perform_async(args)` or `perform_in` / `perform_at`.
          - Do NOT use `perform_later` — that is the ActiveJob API and is not used here.
        SQ
        'activejob' => <<~SQ,
          ## Background Jobs (ActiveJob + Sidekiq)

          This project uses ActiveJob with Sidekiq as the queue adapter. Jobs live in `app/jobs/`.
          - Inherit from `ApplicationJob` (or `ActiveJob::Base`).
          - Enqueue with `MyJob.perform_later(args)` or `set(wait: 5.minutes).perform_later`.
          - Do NOT use `perform_async` — that is the direct Sidekiq API and is not used here.
        SQ
        'both' => <<~SQ
          ## Background Jobs (Sidekiq + ActiveJob)

          This project uses BOTH patterns. Check existing code to determine which to use:
          - `app/jobs/` — ActiveJob: inherit `ApplicationJob`, enqueue with `perform_later`.
          - `app/workers/` — direct Sidekiq: `include Sidekiq::Worker`, enqueue with `perform_async`.
          Follow the pattern of the module you are modifying. Do not mix patterns in the same class.
          **When creating new jobs, prefer ActiveJob** (`app/jobs/` + `perform_later`) unless
          the surrounding code explicitly uses direct Sidekiq workers.
        SQ
      }.freeze

      API = <<~API
        ## API-Only Application

        This is a Rails API-only app. No views or view helpers. Respond with JSON.
        Use serializers or `as_json` / `to_json` following the project's existing pattern.
      API

      RUBOCOP = <<~RC
        ## Code Style (RuboCop)

        This project uses RuboCop. Follow the existing `.rubocop.yml` configuration. NEVER CHANGE THE CONFIGURATION.
        Run `bundle exec rubocop --autocorrect` on files you modify if unsure about style.
      RC

      VERSIONS = {
        4 => <<~V4,
          ## Rails 4.x Specifics

          - Use `before_action` (not `before_filter`, deprecated).
          - Strong Parameters via `params.require(:x).permit(...)` in controllers.
          - Assets pipeline via Sprockets (`app/assets/`).
          - `ActiveRecord::Base` is the model superclass (not `ApplicationRecord`).
          - Use `rake` for tasks (not `rails` — `rails` tasks came in Rails 5).
          - Migrations use `ActiveRecord::Migration` without version suffix.
        V4
        5 => <<~V5,
          ## Rails 5.x Specifics

          - `ApplicationRecord` is the model superclass.
          - `ApplicationController` is the controller superclass.
          - Migrations must specify version: `ActiveRecord::Migration[5.0]` (or 5.1, 5.2).
          - `belongs_to` is required by default (use `optional: true` if nullable).
          - Use `rails` CLI for tasks (not `rake`).
          - System tests with Capybara available via `test/system/`.
        V5
        6 => <<~V6,
          ## Rails 6.x Specifics

          - Webpacker is the default JS bundler (`app/javascript/`).
          - Action Mailbox and Action Text available.
          - Multi-database support via `connects_to`.
          - Migrations: `ActiveRecord::Migration[6.0]` (or 6.1).
          - `insert_all` / `upsert_all` for bulk operations.
          - Zeitwerk autoloader is default.
        V6
        7 => <<~V7,
          ## Rails 7.x Specifics

          - Import maps or jsbundling-rails/cssbundling-rails for assets (no Webpacker).
          - Hotwire (Turbo + Stimulus) is the default frontend approach.
          - Encrypted credentials via `rails credentials:edit`.
          - `query_constraints` for composite primary keys (7.1+).
          - `normalizes` for attribute normalization (7.1+).
          - `generates_token_for` for token generation (7.1+).
          - Migrations: `ActiveRecord::Migration[7.0]` (or 7.1, 7.2).
        V7
        8 => <<~V8
          ## Rails 8.x Specifics

          - Solid Queue, Solid Cache, Solid Cable as default backends.
          - Kamal 2 for deployment.
          - Propshaft as default asset pipeline.
          - Authentication generator: `rails generate authentication`.
          - `params.expect` for strong parameters (safer than `permit`).
          - Migrations: `ActiveRecord::Migration[8.0]` (or 8.1).
          - Script folder: `script/` for one-off scripts.
        V8
      }.freeze
    end
  end
end

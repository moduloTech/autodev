# frozen_string_literal: true

require 'rake/testtask'

# Load Rails-side tasks (notably `:environment`, which `lib/tasks/autodev.rake`
# depends on for `bin/rails autodev:migrate_projects_from_yaml` etc.).
# Phase C closed at v1.0.0-alpha.1, so the deliberate `load_tasks` skip
# documented at the top of `lib/tasks/autodev.rake` is no longer needed.
require_relative 'config/application'
Rails.application.load_tasks

# Re-define the project's `test` task on top of Rails' default one — we want
# the legacy minitest harness (`test/**/*_test.rb`) instead of Rails 8's
# `bin/rails test` runner, which expects different conventions. `clear`
# first so the redefinition replaces (not chains onto) the Rails-supplied
# task.
Rake::Task[:test].clear if Rake::Task.task_defined?(:test)
Rake::TestTask.new(:test) do |t|
  t.libs << 'test' << 'lib'
  t.pattern = 'test/**/*_test.rb'
end

task default: :test

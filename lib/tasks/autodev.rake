# frozen_string_literal: true

# Step 4 of the railsification — rake wrapper around YamlProjectImporter
# (cf. autodev/docs/autospec.md §H).
#
# Invocation: NOT via `bundle exec rake` — the project's Rakefile deliberately
# does NOT call `Rails.application.load_tasks` (see autodev/docs/railsification-
# handoff.md §4: that would conflict with the existing minitest harness's
# `:test` task). Until the supervisor lands in phase C and owns the rake
# wiring, invoke this task explicitly via `bin/rails runner`:
#
#   bin/rails runner '
#     Rake.application.init
#     Rake.application.add_import("lib/tasks/autodev.rake")
#     Rake.application.load_imports
#     Rake::Task["autodev:migrate_projects_from_yaml"].invoke
#   '
#
# Or, more practically until then, instantiate the importer directly:
#
#   bin/rails runner '
#     yaml = YAML.safe_load_file(File.expand_path(ENV.fetch("AUTODEV_CONFIG", "~/.autodev/config.yml")))
#     summary = YamlProjectImporter.new(yaml: yaml).import!(dry_run: ENV["DRY_RUN"] == "1")
#     puts summary
#   '
#
# The task itself lives here for forward compatibility — once the
# Rakefile is wired up in phase C, `bundle exec rake autodev:migrate_projects_from_yaml`
# becomes the canonical entry point and the autodev §H plan (rake one-shot
# during cutover) is reachable without copy-paste.

namespace :autodev do
  desc 'Import ~/.autodev/config.yml `projects:` block into projects + project_app_commands. ' \
       'DRY_RUN=1 logs the summary without writing. AUTODEV_CONFIG=path overrides the file path.'
  task migrate_projects_from_yaml: :environment do
    config_path = File.expand_path(ENV.fetch('AUTODEV_CONFIG', '~/.autodev/config.yml'))
    unless File.exist?(config_path)
      warn "[autodev:migrate_projects_from_yaml] config file not found: #{config_path}"
      exit 1
    end

    yaml = YAML.safe_load_file(config_path, permitted_classes: [Symbol], aliases: true)
    importer = YamlProjectImporter.new(yaml: yaml)
    summary = importer.import!(dry_run: ENV['DRY_RUN'] == '1')
    puts "[autodev:migrate_projects_from_yaml] #{config_path}"
    puts summary
  end
end

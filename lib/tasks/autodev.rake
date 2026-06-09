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

# Helpers extracted from the rake tasks below (Metrics/BlockLength). All
# delegate to `Autodev::OpsCommands` so `bin/autodev`'s CLI flags
# (alpha.7+) and these rake tasks share one source of truth.

def autodev_seed_admin
  email = ENV.fetch('EMAIL') { abort '[autodev:seed_admin] EMAIL=... required' }
  puts Autodev::OpsCommands.seed_admin(email: email)
end

def autodev_sync_memberships
  puts Autodev::OpsCommands.sync_memberships
end

def autodev_link_user
  email = ENV.fetch('EMAIL') { abort '[autodev:link_user] EMAIL=... required' }
  username = ENV.fetch('GITLAB_USERNAME') { abort '[autodev:link_user] GITLAB_USERNAME=... required' }
  puts Autodev::OpsCommands.link_user(email: email, gitlab_username: username)
end

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

  # PR2 of the users-rollout chantier (cf. docs/users-rollout.md §5).
  desc 'Seed an admin User by email. Usage: bin/rails autodev:seed_admin EMAIL=marc@modulotech.fr'
  task(seed_admin: :environment) { autodev_seed_admin }

  desc 'Reconcile project_memberships against GitLab for every user. ' \
       'Idempotent, transactional per user.'
  task(sync_memberships: :environment) { autodev_sync_memberships }

  desc 'Manually link a User to a GitLab username (override for non-standard naming). ' \
       'Usage: bin/rails autodev:link_user EMAIL=marc@modulotech.fr GITLAB_USERNAME=mleclercq'
  task(link_user: :environment) { autodev_link_user }
end

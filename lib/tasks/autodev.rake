# frozen_string_literal: true

# Rake wrappers around `Autodev::OpsCommands` and `YamlProjectImporter`
# (cf. autodev/docs/autospec.md §H).
#
# Invocation: `bin/rails autodev:<task>` — the Rakefile loads Rails tasks
# (since the phase C cutover) and redefines `:test` on top to keep the
# minitest harness intact.

# Helpers extracted from the rake tasks below (Metrics/BlockLength). All
# delegate to `Autodev::OpsCommands` so `bin/autodev`'s CLI flags
# (alpha.7+) and these rake tasks share one source of truth.

def autodev_migrate_projects_from_yaml
  config_path = File.expand_path(ENV.fetch('AUTODEV_CONFIG', '~/.autodev/config.yml'))
  unless File.exist?(config_path)
    warn "[autodev:migrate_projects_from_yaml] config file not found: #{config_path}"
    exit 1
  end

  yaml = YAML.safe_load_file(config_path, permitted_classes: [Symbol], aliases: true)
  summary = YamlProjectImporter.new(yaml: yaml).import!(dry_run: ENV['DRY_RUN'] == '1')
  puts "[autodev:migrate_projects_from_yaml] #{config_path}"
  puts summary
end

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

# One-off backfill for issue #27: existing issues predate the
# `issue_author_name` column, so they keep it NULL and fall back to the raw
# author id in the UI. New tickets get the name at ingest (PollDispatcher);
# this task resolves the name for the old ones via one GitLab API call each.
# Idempotent (only touches NULL/empty rows) and safe to re-run.
def autodev_backfill_issue_author_names
  cfg = Web.config
  client = GitlabHelpers.build_gitlab_client(cfg['gitlab_url'], cfg['gitlab_token'])
  scope = Issue.where(issue_author_name: [nil, ''])
  puts "[autodev:backfill_issue_author_names] #{scope.count} issue(s) missing an author name"
  tally = { updated: 0, failed: 0 }
  scope.find_each { |issue| autodev_backfill_one_author_name(issue, client, tally) }
  puts "[autodev:backfill_issue_author_names] done: #{tally[:updated]} updated, #{tally[:failed]} failed"
end

def autodev_backfill_one_author_name(issue, client, tally)
  name = client.issue(issue.project_path, issue.issue_iid).author&.name
  return if name.blank?

  issue.update_column(:issue_author_name, name)
  tally[:updated] += 1
rescue StandardError => e
  tally[:failed] += 1
  warn "  ##{issue.issue_iid} (#{issue.project_path}): #{e.message}"
end

# Autodev #53. Reports by default — it deletes rows, so the destructive half is
# opt-in, and VACUUM (exclusive lock, needs free disk equal to the file) is a
# second opt-in on top. Back the database up first; the production procedure is
# in docs/superpowers/specs/2026-08-11-bound-pipeline-watch-design.md.
def autodev_compact_activity_events
  Autodev::ActivityEventCompaction.new(apply: ENV['APPLY'] == '1', vacuum: ENV['VACUUM'] == '1').run
end

namespace :autodev do
  desc 'Import ~/.autodev/config.yml `projects:` block into projects + project_app_commands. ' \
       'DRY_RUN=1 logs the summary without writing. AUTODEV_CONFIG=path overrides the file path.'
  task(migrate_projects_from_yaml: :environment) { autodev_migrate_projects_from_yaml }

  # PR2 of the users-rollout chantier (cf. docs/users-rollout.md §5).
  desc 'Seed an admin User by email. Usage: bin/rails autodev:seed_admin EMAIL=marc@modulotech.fr'
  task(seed_admin: :environment) { autodev_seed_admin }

  desc 'Reconcile project_memberships against GitLab for every user. ' \
       'Idempotent, transactional per user.'
  task(sync_memberships: :environment) { autodev_sync_memberships }

  desc 'Manually link a User to a GitLab username (override for non-standard naming). ' \
       'Usage: bin/rails autodev:link_user EMAIL=marc@modulotech.fr GITLAB_USERNAME=mleclercq'
  task(link_user: :environment) { autodev_link_user }

  desc 'Backfill issue_author_name for pre-existing issues (one GitLab call per issue). ' \
       'Idempotent — only fills NULL/empty rows. Usage: bin/rails autodev:backfill_issue_author_names'
  task(backfill_issue_author_names: :environment) { autodev_backfill_issue_author_names }

  desc 'Delete superseded occurrences of collapsible activity entries, keeping the newest per issue. ' \
       'Reports only unless APPLY=1. VACUUM=1 reclaims the file afterwards. Idempotent.'
  task(compact_activity_events: :environment) { autodev_compact_activity_events }
end

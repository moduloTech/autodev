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

# Autodev #75. The arrears of the unreachable clarification pickup: every row
# parked in `needs_clarification` is re-asked "did a human answer?", and the ones
# that did go back into the queue. Reads the `issues` table rather than GitLab's
# label filter, so it reaches the requests whose ticket is still on `label_doing`
# and which `dispatch_new_issues` therefore never sees. Reports unless APPLY=1;
# idempotent (a re-armed row leaves the population).
def autodev_recheck_clarifications
  Autodev::ClarificationSweep.new(config: Web.config, apply: ENV['APPLY'] == '1').run
end

# Autodev #88. The arrears of the revoked review token: the requests given up on
# `review_failures_exhausted` that were never reviewed at all (`review_count` 0)
# go back to the pipeline check, where the review they never got runs. Reports
# unless APPLY=1; LIMIT caps how many one run re-arms (3 = max_workers) and the
# manual re-run is the spacing; INCLUDE_AUTHOR_HANDBACK=1 widens the ownership
# filter to the tickets autodev itself handed back to their author. Idempotent (a
# re-armed row leaves the population, and one re-armed once is never re-armed
# again).
# `LIMIT` is read through the sweep's own declaration, which carries the range as
# well as the type: `NumericSettings.integer` alone accepted `LIMIT=30` — one
# keystroke from 3 — and re-armed the whole arrears in a single run. A rejected
# value raises `ConfigError` and the task aborts before a row is examined.
def autodev_recheck_review_arrears
  Autodev::ReviewArrearsSweep.new(config: Web.config, apply: ENV['APPLY'] == '1',
                                  limit: Autodev::ReviewArrearsSweep.limit_from(ENV.fetch('LIMIT', nil)),
                                  include_author_handback: ENV['INCLUDE_AUTHOR_HANDBACK'] == '1').run
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

  desc 'Re-ask GitLab whether the requests parked in needs_clarification have been answered, ' \
       'and re-queue the ones that have. Reports only unless APPLY=1. Idempotent.'
  task(recheck_clarifications: :environment) { autodev_recheck_clarifications }

  desc 'Send the requests given up on an exhausted review budget without ever having been reviewed ' \
       'back to the pipeline check. Reports only unless APPLY=1. LIMIT=N per run (default 3, max 10), ' \
       'INCLUDE_AUTHOR_HANDBACK=1 widens the ownership filter. Idempotent.'
  task(recheck_review_arrears: :environment) { autodev_recheck_review_arrears }
end

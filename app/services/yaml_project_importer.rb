# frozen_string_literal: true

# Step 4 of the railsification — import the `projects:` block of
# `~/.autodev/config.yml` into the `projects` + `project_app_commands` tables
# (cf. autodev/docs/autospec.md §H).
#
# Idempotent + transactional + dry-run safe. Scope is intentionally narrow:
# only the fields the step-2 schema knows about land in the DB. Per-project
# poller settings (target_branch, labels_*, dc_timeout, etc.) still live in
# YAML and are read by lib/autodev/poller.rb until the phase C cutover ports
# the poller itself.
#
# Lifecycle:
#   1. `validate!` walks the YAML read-only. Aborts before any INSERT if a
#      row is missing `path`, has a malformed `app:` block, etc. Reports
#      every issue in one shot.
#   2. Inside a single `ApplicationRecord.transaction`:
#      - For each project: `find_or_initialize_by(gitlab_path:)`, assign
#        the schema fields, save.
#      - `project.app_commands.destroy_all` then re-create from `app:`.
#        Wiping+rebuilding makes the DB match the YAML exactly on each run.
#   3. Returns a `Summary` struct (created/updated counts + per-category
#      command counts + warnings).
#
# In dry-run mode (`dry_run: true`) the transaction rolls back at the end
# so the operator can preview the summary against a real DB without writing.
#
# Usage:
#   importer = YamlProjectImporter.new(yaml: config_hash)
#   importer.validate!                        # raises if YAML is malformed
#   summary = importer.import!                # writes
#   summary = importer.import!(dry_run: true) # logs, rolls back
class YamlProjectImporter
  Summary = Struct.new(:created, :updated, :app_commands_by_category, :warnings, :dry_run) do
    def to_s
      lines = [
        "Projects: #{created} created, #{updated} updated.",
        "App commands: #{app_commands_by_category.map { |k, v| "#{k}=#{v}" }.join(', ')}."
      ]
      lines << "Warnings:\n  - #{warnings.join("\n  - ")}" if warnings.any?
      lines << '(dry-run — no rows written)' if dry_run
      lines.join("\n")
    end
  end

  class ValidationError < StandardError; end

  APP_COMMAND_CATEGORIES = %w[setup test lint run].freeze

  # Scalar/list per-project config keys mirrored onto `projects` columns.
  # `app:` is handled separately (project_app_commands); `path`/`name` map to
  # gitlab_path/name. Phase 1 columnized the documented keys; phase 2 added the
  # "advanced" ones (model, effort, parallel_agents, split_implementation,
  # *_agent) — every per-project key now has a column.
  CONFIG_KEYS = %w[target_branch labels_todo label_doing label_done label_attention extra_prompt
                   dc_timeout max_retries retry_backoff stagnation_threshold
                   clone_depth sparse_checkout post_completion post_completion_timeout
                   mr_review_timeout model effort parallel_agents split_implementation
                   implementer_agent test_writer_agent mr_fixer_agent].freeze

  def initialize(yaml:)
    @yaml = yaml || {}
    @projects_yaml = Array(@yaml['projects'])
    @warnings = []
  end

  def validate!
    errors = Validator.validate(@projects_yaml)
    raise ValidationError, "Invalid projects YAML:\n  - #{errors.join("\n  - ")}" if errors.any?
  end

  def import!(dry_run: false)
    validate!
    counts = { created: 0, updated: 0, app_commands_by_category: Hash.new(0) }

    ApplicationRecord.transaction do
      @projects_yaml.each { |entry| import_entry(entry, counts) }
      raise ActiveRecord::Rollback if dry_run
    end

    build_summary(counts, dry_run: dry_run)
  end

  private

  def build_summary(counts, dry_run:)
    Summary.new(
      counts[:created], counts[:updated], counts[:app_commands_by_category], @warnings, dry_run
    )
  end

  def import_entry(entry, counts)
    gitlab_path = entry.fetch('path').to_s.strip
    project = Project.find_or_initialize_by(gitlab_path: gitlab_path)
    was_new = project.new_record?
    project.assign_attributes(slug: slug_for(gitlab_path), name: name_for(entry, gitlab_path))
    assign_config_fields(project, entry)
    project.save!

    was_new ? counts[:created] += 1 : counts[:updated] += 1
    rebuild_app_commands(project, entry['app'], counts)
  end

  # Copy each config key the YAML sets onto the matching column; clear the
  # column when the key is absent, so a re-import stays an exact mirror of the
  # YAML (same contract as the destroy_all+rebuild for app commands).
  def assign_config_fields(project, entry)
    CONFIG_KEYS.each { |key| project[key] = entry[key] }
  end

  def slug_for(path)
    # Matches Web::Helpers#project_slug — `/` is the only character that
    # has to be escaped (a path can't contain `__` by GitLab's rules), so
    # gsub is sufficient. NOT `tr('/', '__')` — `tr` is char-to-char and
    # would silently truncate `__` to `_`.
    path.gsub('/', '__')
  end

  def name_for(entry, path)
    return entry['name'] if entry['name'].is_a?(String) && entry['name'].strip.length.positive?

    path.split('/').last
  end

  def rebuild_app_commands(project, app, counts)
    project.app_commands.destroy_all
    return unless app.is_a?(Hash)

    %w[setup test lint].each { |cat| insert_simple_commands(project, app[cat], cat, counts) }
    insert_run_entries(project, app['run'], counts)
  end

  def insert_simple_commands(project, entries, category, counts)
    Array(entries).each_with_index do |cmd, idx|
      project.app_commands.create!(category: category, command: cmd, position: idx)
      counts[:app_commands_by_category][category] += 1
    end
  end

  def insert_run_entries(project, entries, counts)
    Array(entries).each_with_index do |entry, idx|
      project.app_commands.create!(
        category: 'run',
        command: entry.fetch('command'),
        port: entry['port'],
        position: idx
      )
      counts[:app_commands_by_category]['run'] += 1
    end
  end
end

require_relative 'yaml_project_importer/validator'

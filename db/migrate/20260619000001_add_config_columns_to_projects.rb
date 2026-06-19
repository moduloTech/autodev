# frozen_string_literal: true

# Phase 1 of moving per-project config out of ~/.autodev/config.yml's
# `projects:` block and into the DB (task #9; follows the global-config
# slimming of task #4). This migration is ADDITIVE ONLY — it adds the columns
# and `YamlProjectImporter` starts populating them, but the runtime still reads
# the YAML hash (IssueProcessJob#lookup_project_config). The read-path cutover,
# the web CRUD form, and the YAML removal are later phases.
#
# Flat columns (one per config key) rather than a JSON blob, so the eventual
# edit form and the model-side validations can work per-field. The three list
# fields (labels_todo / sparse_checkout / post_completion) are JSON because
# SQLite has no array type — same approach as project_app_commands.command.
# The `app:` block already lives in project_app_commands, so it's not here.
# The "advanced" keys (model, effort, parallel_agents, split_implementation,
# *_agent) stay YAML-only for now — they're undocumented, unvalidated, and
# rarely used; they can get columns later if needed.
#
# `if_not_exists`-aware so it's a no-op on a DB that already has the columns.
class AddConfigColumnsToProjects < ActiveRecord::Migration[8.1]
  def change # rubocop:disable Metrics/MethodLength
    add_column :projects, :target_branch,           :string,  if_not_exists: true
    add_column :projects, :labels_todo,             :json,    if_not_exists: true
    add_column :projects, :label_doing,             :string,  if_not_exists: true
    add_column :projects, :label_done,              :string,  if_not_exists: true
    add_column :projects, :extra_prompt,            :text,    if_not_exists: true
    add_column :projects, :dc_timeout,              :integer, if_not_exists: true
    add_column :projects, :max_retries,             :integer, if_not_exists: true
    add_column :projects, :retry_backoff,           :integer, if_not_exists: true
    add_column :projects, :stagnation_threshold,    :integer, if_not_exists: true
    add_column :projects, :clone_depth,             :integer, if_not_exists: true
    add_column :projects, :sparse_checkout,         :json,    if_not_exists: true
    add_column :projects, :post_completion,         :json,    if_not_exists: true
    add_column :projects, :post_completion_timeout, :integer, if_not_exists: true
  end
end

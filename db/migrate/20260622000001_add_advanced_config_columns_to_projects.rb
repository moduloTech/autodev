# frozen_string_literal: true

# Task #9 phase 2 follow-up: columnize the per-project "advanced" config keys
# that phase 1 (migration 20260619000001) deliberately left YAML-only because
# they were undocumented and unvalidated. Now that the runtime read path goes
# through the DB (IssueProcessJob#lookup_project_config), these get columns
# too — alongside template documentation (Config::TEMPLATE) and validations
# (lib/autodev/project_validator.rb + Project) — so they stop being a special
# case layered in from the YAML, and the eventual edit form (phase 3) can
# expose them per-field like every other key.
#
#   model / effort            → danger-claude `-m` / `-e` overrides (strings)
#   parallel_agents           → enable parallel-agent implementation (boolean)
#   split_implementation      → split impl into code + tests (boolean)
#   implementer_agent /
#   test_writer_agent /
#   mr_fixer_agent            → per-role agent override (strings)
#
# Nullable, no default: an unset key stays NULL → omitted by
# Project#to_project_config, exactly like an absent YAML key.
class AddAdvancedConfigColumnsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :model,                :string,  if_not_exists: true
    add_column :projects, :effort,               :string,  if_not_exists: true
    add_column :projects, :parallel_agents,      :boolean, if_not_exists: true
    add_column :projects, :split_implementation, :boolean, if_not_exists: true
    add_column :projects, :implementer_agent,    :string,  if_not_exists: true
    add_column :projects, :test_writer_agent,    :string,  if_not_exists: true
    add_column :projects, :mr_fixer_agent,       :string,  if_not_exists: true
  end
end

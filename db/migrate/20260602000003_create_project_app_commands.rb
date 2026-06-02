# frozen_string_literal: true

# Step 2 of the railsification (cf. autodev/docs/autospec.md §A and
# autodev/docs/railsification-handoff.md §6).
#
# Replaces the `app:` block of `~/.autodev/config.yml` (one row per command).
# `command` stores the Docker-CMD-style array verbatim (e.g.
# ["bundle", "install"]). `position` preserves the user-defined order, which
# the YAML representation guarantees today via list ordering and which the
# Phase C rake migration must respect to keep `setup` steps run in sequence.
class CreateProjectAppCommands < ActiveRecord::Migration[8.1]
  def change
    create_table :project_app_commands do |t|
      t.references :project, null: false, foreign_key: true
      t.string :category, null: false # 'setup' | 'test' | 'lint' | 'run'
      t.json :command, null: false
      t.integer :port
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    add_index :project_app_commands, %i[project_id category position]
  end
end

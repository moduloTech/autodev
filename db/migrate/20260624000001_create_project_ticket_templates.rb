# frozen_string_literal: true

# Per-project ticket templates (task #14). Each project may define one or
# more named templates (e.g. "évolution", "bug") whose markdown body
# becomes the structure AutoSpec imposes when drafting a ticket on that
# project — replacing the manual copy-paste of a template into the chat.
# `create_table` / `add_index` are `if_not_exists: true` so the boot-time
# `auto_migrate` initializer is idempotent across fresh installs and
# upgrades (cf. CLAUDE.md "SQLite Schema").
class CreateProjectTicketTemplates < ActiveRecord::Migration[8.1]
  def change # rubocop:disable Metrics/MethodLength
    create_table :project_ticket_templates, if_not_exists: true do |t|
      t.references :project, null: false, foreign_key: true
      t.string  :name,     null: false # display label, e.g. "Évolution"
      t.string  :slug,     null: false # stable key, e.g. "evolution"
      t.text    :body,     null: false # the markdown structure to follow
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    add_index :project_ticket_templates, %i[project_id slug],
              unique: true, if_not_exists: true
    add_index :project_ticket_templates, %i[project_id position],
              if_not_exists: true
  end
end

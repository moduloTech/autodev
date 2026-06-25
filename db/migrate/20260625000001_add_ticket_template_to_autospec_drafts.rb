# frozen_string_literal: true

# Record which ticket template a draft was started from (tasks #14 follow-up).
# Nullable: a draft may be created without choosing a template (blank canvas
# or GitLab import). When set, AutoSpec verifies the draft against this
# template; when null, it proposes the best-fit one. FK nullifies on template
# delete so a removed template just drops the link. `if_not_exists` keeps the
# boot-time auto_migrate idempotent (cf. CLAUDE.md "SQLite Schema").
class AddTicketTemplateToAutospecDrafts < ActiveRecord::Migration[8.1]
  def change
    return if column_exists?(:autospec_drafts, :ticket_template_id)

    add_reference :autospec_drafts, :ticket_template, null: true,
                                                      foreign_key: { to_table: :project_ticket_templates,
                                                                     on_delete: :nullify }
  end
end

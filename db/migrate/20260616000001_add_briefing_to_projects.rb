# frozen_string_literal: true

# Project briefing columns — populated by an hourly Solid Queue job that
# clones the project's `staging` branch and asks danger-claude to
# summarise the codebase (domain, conventions, lexicon, key files). The
# resulting briefing is injected as a cacheable block of the AutoSpec
# chat system prompt so Claude has project-aware context for ticket
# drafting without paying the latency cost on every turn.
#
# - `briefing_text` — the generated markdown (nullable: empty when no
#   briefing has ever been generated, e.g. fresh project or
#   danger-claude unavailable).
# - `briefing_generated_at` — last successful refresh timestamp.
# - `briefing_error` — last refresh failure reason (one-line); reset
#   when a refresh succeeds. Useful for the admin /admin/users-style
#   debugging surfaces.
class AddBriefingToProjects < ActiveRecord::Migration[8.1]
  def change
    add_column :projects, :briefing_text,         :text,     if_not_exists: true
    add_column :projects, :briefing_generated_at, :datetime, if_not_exists: true
    add_column :projects, :briefing_error,        :text,     if_not_exists: true
  end
end

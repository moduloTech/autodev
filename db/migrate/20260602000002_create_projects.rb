# frozen_string_literal: true

# Step 2 of the railsification (cf. autodev/docs/autospec.md §A and
# autodev/docs/railsification-handoff.md §6).
#
# `projects` will replace the per-project `projects:` block currently kept in
# `~/.autodev/config.yml`. Phase B leaves it empty — `lib/autodev/poller.rb`
# keeps reading the YAML. Phase C runs the `autodev:migrate_projects_from_yaml`
# rake (see autospec.md §H) to populate it, then deletes the legacy code.
class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      # e.g. "moduloTech/autodev" — full GitLab namespace + path.
      t.string :gitlab_path, null: false
      # URL-safe form ("group__project") matching `Web::Helpers#project_slug`.
      t.string :slug, null: false
      t.string :name
      t.string :default_locale, null: false, default: 'fr'

      t.timestamps
    end

    add_index :projects, :gitlab_path, unique: true
    add_index :projects, :slug, unique: true
  end
end

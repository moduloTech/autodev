# frozen_string_literal: true

# Step 2 of the railsification (cf. autodev/docs/autospec.md §J and
# autodev/docs/railsification-handoff.md §6).
#
# Maps users to projects with a role. Per autospec §J: owner inherits all
# contributor capabilities and additionally gates "send to AutoDev" + draft
# approval. One row per (user, project) — promotions/demotions are an UPDATE,
# not a new row.
class CreateProjectMemberships < ActiveRecord::Migration[8.1]
  def change
    create_table :project_memberships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.string :role, null: false # 'contributor' | 'owner'

      t.timestamps
    end

    add_index :project_memberships, %i[user_id project_id], unique: true
    add_index :project_memberships, %i[project_id role]
  end
end

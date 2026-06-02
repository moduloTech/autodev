# frozen_string_literal: true

# Step 2 of the railsification (cf. autodev/docs/autospec.md §A and
# autodev/docs/railsification-handoff.md §6).
#
# `users` is the Microsoft 365 SSO subject record. Phase B leaves this table
# empty — no code reads or writes it. Step 3 (Devise + omniauth Azure AD)
# will populate it on first sign-in; until then, it sits alongside the
# Sequel-side `issues` / `activity_events` tables without interfering.
class CreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.string :email, null: false
      t.string :name
      # Azure AD subject identifier ("oid" claim). Nullable so step-3 Devise
      # can add it without backfilling rows the omniauth flow has never seen.
      t.string :microsoft_uid
      t.string :locale, null: false, default: 'fr'

      t.timestamps
    end

    add_index :users, :email, unique: true
    add_index :users, :microsoft_uid, unique: true, where: 'microsoft_uid IS NOT NULL'
  end
end

# frozen_string_literal: true

# Step 3 of the railsification (cf. autodev/docs/autospec.md §A, §C item 3).
#
# Adds the columns Devise's `:trackable` module reads/writes after every
# successful sign-in. Step 2's `users` table already covers everything
# `:omniauthable` needs (Microsoft 365 SSO → User.from_omniauth populates
# `microsoft_uid`, `email`, `name`).
#
# We deliberately DO NOT add the `:database_authenticatable` columns
# (`encrypted_password`, `reset_password_token`, ...) — Autodev's auth model
# is SSO-only, never local passwords.
class AddDeviseTrackableToUsers < ActiveRecord::Migration[8.1]
  def change
    change_table :users do |t|
      t.integer :sign_in_count, default: 0, null: false
      t.datetime :current_sign_in_at
      t.datetime :last_sign_in_at
      t.string :current_sign_in_ip
      t.string :last_sign_in_ip
    end
  end
end

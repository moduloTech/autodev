# frozen_string_literal: true

# Step 3 of the railsification (cf. autodev/docs/autospec.md §C item 3 —
# "Auth Devise + omniauth Azure AD + sessions table").
#
# Server-side session storage via `activerecord-session_store`. Compared to
# the default cookie store this:
#   - lets the server invalidate sessions at will (forced sign-out, audit),
#   - keeps the cookie tiny (only `session_id`), so omniauth callbacks with
#     a large state param don't bloat every subsequent request,
#   - lays a foundation for later admin features ("sign out everyone").
#
# Standard schema from `activerecord-session_store` ≥ 2.0.
class CreateSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :sessions do |t|
      t.string :session_id, null: false
      t.text :data
      t.timestamps
    end

    add_index :sessions, :session_id, unique: true
    add_index :sessions, :updated_at
  end
end

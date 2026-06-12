# frozen_string_literal: true

# Phase D step 9 — AutoSpec chat history (cf. autodev/docs/autospec.md §G).
#
# One row per turn in the conversation. `role` matches Anthropic's API
# vocabulary ('user' | 'assistant'). `content` holds the textual payload.
# `tool_calls` is an array of `tool_use` blocks emitted by the assistant
# in that turn, each enriched with an `applied_at` stamp once the CSM
# clicks the matching suggestion button (the model does NOT execute the
# tools — see §G "Application côté serveur" for the inversion). The
# synthetic `tool_result` blocks built on the next request are derived
# from these stamps and are NOT persisted.
class CreateAutospecMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :autospec_messages, if_not_exists: true do |t|
      t.references :autospec_draft, null: false, foreign_key: true
      t.string :role, null: false
      t.text   :content
      t.json   :tool_calls, default: []
      t.timestamps
    end
  end
end

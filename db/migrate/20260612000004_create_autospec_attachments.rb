# frozen_string_literal: true

# Phase D step 9 — AutoSpec captures (cf. autodev/docs/autospec.md §F).
#
# Thin AR row whose only purpose is to anchor a `has_one_attached :file`
# ActiveStorage attachment to a draft. The actual file lives in the
# active_storage_* tables (and on disk via the local service — see
# config/storage.yml). At submission time the orchestration service
# downloads each blob, uploads it to GitLab via the issue uploads
# endpoint, and rewrites the draft markdown to point at the GitLab URL
# (§F flux à deux temps).
class CreateAutospecAttachments < ActiveRecord::Migration[8.1]
  def change
    create_table :autospec_attachments, if_not_exists: true do |t|
      t.references :autospec_draft, null: false, foreign_key: true
      t.timestamps
    end
  end
end

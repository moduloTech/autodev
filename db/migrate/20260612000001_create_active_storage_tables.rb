# frozen_string_literal: true

# Phase D step 9 — AutoSpec attachments (cf. autodev/docs/autospec.md §F).
#
# Standard Rails 8.1 ActiveStorage schema (the same three tables
# `bin/rails active_storage:install` would generate from the railtie's
# template). Inlined here because we drive migrations through the
# `auto_migrate.rb` initializer rather than `bin/rails db:migrate` —
# our minimal railtie set doesn't ship the `db:` rake namespace.
#
# `if_not_exists: true` matches the rest of the migrations in this repo
# so re-running against an existing DB is a no-op (relevant for prod
# brew upgrades that boot the new code against ~/.autodev/autodev.db).
class CreateActiveStorageTables < ActiveRecord::Migration[8.1]
  def change
    create_active_storage_blobs
    add_active_storage_blobs_index
    create_active_storage_attachments
    add_active_storage_attachments_index
    create_active_storage_variant_records
    add_active_storage_variant_records_index
  end

  private

  def create_active_storage_blobs
    create_table :active_storage_blobs, if_not_exists: true do |t|
      t.string   :key,          null: false
      t.string   :filename,     null: false
      t.string   :content_type
      t.text     :metadata
      t.string   :service_name, null: false
      t.bigint   :byte_size,    null: false
      t.string   :checksum
      t.datetime :created_at, null: false
    end
  end

  def add_active_storage_blobs_index
    add_index :active_storage_blobs, :key, unique: true,
                                           name: 'index_active_storage_blobs_on_key',
                                           if_not_exists: true
  end

  def create_active_storage_attachments
    create_table :active_storage_attachments, if_not_exists: true do |t|
      t.string :name, null: false
      t.references :record, null: false, polymorphic: true, index: false
      t.references :blob,   null: false,
                            foreign_key: { to_table: :active_storage_blobs }
      t.datetime :created_at, null: false
    end
  end

  def add_active_storage_attachments_index
    add_index :active_storage_attachments,
              %i[record_type record_id name blob_id],
              unique: true,
              name: 'index_active_storage_attachments_uniqueness',
              if_not_exists: true
  end

  def create_active_storage_variant_records
    create_table :active_storage_variant_records, if_not_exists: true do |t|
      t.belongs_to :blob, null: false, index: false,
                          foreign_key: { to_table: :active_storage_blobs }
      t.string :variation_digest, null: false
    end
  end

  def add_active_storage_variant_records_index
    add_index :active_storage_variant_records,
              %i[blob_id variation_digest],
              unique: true,
              name: 'index_active_storage_variant_records_uniqueness',
              if_not_exists: true
  end
end

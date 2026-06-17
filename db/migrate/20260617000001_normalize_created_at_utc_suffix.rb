# frozen_string_literal: true

# Data fix: strip the trailing " UTC" from `created_at` values that AR wrote
# before the models declared `created_at` as a :datetime attribute.
#
# `activity_events.created_at` (and `issues.created_at`) are TEXT columns
# inherited from the legacy Sequel schema. Until the matching `attribute
# :created_at, :datetime` overrides landed, AR serialized the timestamp via
# `Time#to_s`, producing "2026-06-11 11:13:03 UTC". SQLite's `date()` /
# `datetime()` return NULL on that string, which silently zeroed the dashboard
# "Activité de la semaine" sparkline (it groups by `date(created_at)`).
#
# This normalizes the already-written rows so the format matches what AR now
# emits ('YYYY-MM-DD HH:MM:SS', UTC, no zone word). Idempotent: the WHERE
# clause only touches rows still carrying the suffix.
class NormalizeCreatedAtUtcSuffix < ActiveRecord::Migration[8.1]
  TABLES = %w[activity_events issues].freeze

  def up
    TABLES.each do |table|
      next unless table_exists?(table) && column_exists?(table, :created_at)

      execute(<<~SQL.squish)
        UPDATE #{table}
        SET created_at = replace(created_at, ' UTC', '')
        WHERE created_at LIKE '% UTC'
      SQL
    end
  end

  # Re-appending " UTC" would only reintroduce the bug; nothing to undo.
  def down; end
end

# frozen_string_literal: true

# Autodev #96: an hourly counter of GitLab API calls, split by kind (read /
# write) and endpoint (the gem method name). One row per
# `(hour_bucket, kind, endpoint)` triple, bumped by an upsert rather than
# inserted per call — at the instruction's own estimate (900-1300 calls/hour
# across ~20 distinct endpoints) this is a few dozen rows touched per hour,
# not one row per request. See `GitlabRequestCounter` (the writer) and
# `docs/superpowers/specs/2026-09-03-count-gitlab-requests-design.md`.
#
# `if_not_exists: true` like every migration here — the production database
# predates ActiveRecord and `config/initializers/auto_migrate.rb` re-runs the
# whole set on every boot.
class CreateGitlabRequestStats < ActiveRecord::Migration[8.1]
  def change
    create_table :gitlab_request_stats, if_not_exists: true do |t|
      t.datetime :hour_bucket, null: false
      t.string :kind, null: false
      t.string :endpoint, null: false
      t.integer :count, null: false, default: 0

      t.timestamps
    end

    add_index :gitlab_request_stats, %i[hour_bucket kind endpoint], unique: true, if_not_exists: true
  end
end

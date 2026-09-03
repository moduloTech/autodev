# frozen_string_literal: true

# Autodev #96: one row per GitLab transport failure — the outage family
# `GitlabHelpers::TRANSPORT_ERRORS` already names (Autodev #62's third
# round: connection refused, timeout, TLS, EOF, and a GitLab response GitLab
# itself could not honour). At the observed 1-2% background failure rate
# this is tens of rows a day, so a log (unlike `gitlab_request_stats`,
# which is a counter) is the right shape — it is what turns four manual
# probes into an actual rate and an actual hourly curve (instruction point
# 3). `occurred_at` carries millisecond precision on purpose: an hourly
# curve needs to place a failure inside its hour reliably, and second
# precision on a bursty signal is not enough to tell two failures apart in
# a trace. See `GitlabRequestCounter` (the writer) and
# `docs/superpowers/specs/2026-09-03-count-gitlab-requests-design.md`.
#
# `if_not_exists: true` like every migration here — the production database
# predates ActiveRecord and `config/initializers/auto_migrate.rb` re-runs the
# whole set on every boot.
class CreateGitlabTransportFailures < ActiveRecord::Migration[8.1]
  def change
    create_table :gitlab_transport_failures, if_not_exists: true do |t|
      t.datetime :occurred_at, null: false, precision: 3
      t.string :kind, null: false
      t.string :endpoint, null: false
      t.string :error_class, null: false
      t.string :error_message
      t.string :caller_location

      t.timestamps
    end

    add_index :gitlab_transport_failures, :occurred_at, if_not_exists: true
  end
end

# frozen_string_literal: true

# Adds the ticket author's GitLab display name to the issues table so the
# dashboard can show *who* asked for each request (task #27) instead of only
# the opaque numeric author id captured at ingest.
#
# The name is available on the GitLab issue payload at ingest time
# (`gl_issue.author.name`); `Autodev::PollDispatcher#find_or_create_issue`
# now persists it alongside `issue_author_id`. Existing rows predate the
# column and keep it NULL — the view falls back to `#<author_id>` for those.
#
# `if_not_exists: true` keeps the migration idempotent, matching the
# convention every other migration in this project uses (fresh installs and
# upgrades from the pre-rails Sequel DB run the same file).
class AddIssueAuthorNameToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :issue_author_name, :string, if_not_exists: true
  end
end

# frozen_string_literal: true

# The discussion threads a fix round verified and pushed but could not resolve
# on GitLab (Autodev #125, amendment 1).
#
# A resolution lost to a network cut used to be lost for good: the next round
# found the correction already on the branch, measured an empty diff, left the
# thread open as `:unchanged`, and `stagnation_threshold` rounds later gave the
# request up on a stagnation that was one lost write. The next round now
# resolves such a thread directly, without fixing it again, and this column is
# what it remembers them by.
#
# A JSON object `{ "<discussion_id>" => "<ISO8601 UTC time of the verdict>" }`:
# the time is what tells a thread nobody touched since the verdict from one a
# human replied on, which must be read and fixed again. NULL means empty.
#
# `if_not_exists: true` like every migration here — the production database
# predates ActiveRecord and `config/initializers/auto_migrate.rb` re-runs the
# whole set on every boot.
class AddPendingResolutionsToIssues < ActiveRecord::Migration[8.1]
  def up
    add_column :issues, :pending_resolutions, :text, if_not_exists: true
  end

  def down
    remove_column :issues, :pending_resolutions, if_exists: true
  end
end

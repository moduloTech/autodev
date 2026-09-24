# frozen_string_literal: true

# When `ClarificationWatch` last read GitLab for a parked row absent from the
# todo list (Autodev #86, adversarial review of the alpha-55 lot).
#
# The watch re-read such a row on every cycle so its flag could follow the
# ticket: 720 reads a day per row at production's `poll_interval: 120`, for as
# long as nobody closes the ticket — and flag-and-keep means nobody has to. The
# database copy of 04/09/2026 held twelve parked rows, nine of them assigned to
# humans by 23/09: a repeat of that backlog would cost 6 480 reads a day, more
# than all of autodev's GitLab traffic measured on 22/09 (6 060). The owner set
# the re-read cadence to fifteen minutes on 23/09/2026; this column is the clock
# it is spaced on, the way `infra_recheck_at` and `dormant_recheck_at` space
# their own passes.
#
# `if_not_exists: true` like every migration here — the production database
# predates ActiveRecord and `config/initializers/auto_migrate.rb` re-runs the
# whole set on every boot. NULL means "never read", which reads at once.
class AddClarificationReadAtToIssues < ActiveRecord::Migration[8.1]
  def up
    add_column :issues, :clarification_read_at, :datetime, if_not_exists: true
  end

  def down
    remove_column :issues, :clarification_read_at, if_exists: true
  end
end

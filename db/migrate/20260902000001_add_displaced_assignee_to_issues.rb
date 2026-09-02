# frozen_string_literal: true

# Who autodev took the ticket from, so it can give it back to them (Autodev #98).
#
# On GitLab Community an issue holds ONE assignee, so autodev cannot be *added*
# to a ticket a human holds — it can only replace them. `ReviewArrearsSweep`
# needs to do exactly that to re-arm the arrears of the revoked review token, and
# the handback at the end of the work went to `issues.issue_author_id`, which is
# a different person on 4 of the 20 rows and, on one of them, a deactivated
# account.
#
# NULL is the normal case and means "autodev displaced nobody": the ticket was
# already assigned to it, or to nobody, and the handback keeps going to the
# author exactly as before. Only a takeover writes this column, and only the
# handback reads it.
#
# `if_not_exists: true` like every migration here — the production database
# predates ActiveRecord and `config/initializers/auto_migrate.rb` re-runs the
# whole set on every boot.
class AddDisplacedAssigneeToIssues < ActiveRecord::Migration[8.1]
  def up
    add_column :issues, :displaced_assignee_id, :integer, if_not_exists: true
  end

  def down
    remove_column :issues, :displaced_assignee_id, if_exists: true
  end
end

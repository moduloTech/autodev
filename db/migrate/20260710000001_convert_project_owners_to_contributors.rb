# frozen_string_literal: true

# Data fix (Autodev #38): owner becomes a 100% manual designation, made from
# a project's Team tab (ProjectOwnersController) instead of being derived
# from GitLab access_level >= 40 (Maintainer) by GitlabMembershipSync. Every
# pre-existing `owner` row was granted by the now-removed automatic mapping,
# so none of them reflect an actual manual decision — they're downgraded to
# `contributor` here. After this runs, no project has an owner until an
# admin (or, going forward, another owner) designates one.
#
# Idempotent: re-running only ever downgrades rows still tagged `owner`, so
# a manual owner designated after this migration first ran is untouched by
# a later re-run (the boot-time `auto_migrate` initializer only re-applies
# migrations that haven't recorded a `schema_migrations` row, but the SQL
# itself would also be a no-op if it somehow ran twice).
class ConvertProjectOwnersToContributors < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:project_memberships)

    execute(<<~SQL.squish)
      UPDATE project_memberships SET role = 'contributor' WHERE role = 'owner'
    SQL
  end

  # Data fix — the original manual/automatic distinction isn't recoverable,
  # so there's nothing meaningful to roll back to.
  def down; end
end

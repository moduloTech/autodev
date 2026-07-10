# frozen_string_literal: true

require_relative '../rails_helper'

# Data fix (Autodev #38): every pre-existing `owner` row was granted by the
# now-removed automatic GitlabMembershipSync mapping, not by a manual
# decision, so the migration downgrades all of them to `contributor`.
# `test/rails_helper.rb` already runs every file under `db/migrate/` once per
# process (including this one) before any test executes, which is what makes
# `ConvertProjectOwnersToContributors` resolvable here as a top-level
# constant — the class itself is exercised directly against rows inserted
# after that initial run, mirroring the pattern for a "runs on an
# already-migrated DB, but real prod data existed before it" data fix.
class ConvertProjectOwnersToContributorsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: 'u@modulotech.fr', name: 'U')
    @project = Project.create!(gitlab_path: 'group/proj', slug: 'group__proj')
  end

  def test_existing_owner_rows_become_contributors
    owner_membership = ProjectMembership.create!(user: @user, project: @project, role: 'owner')

    ConvertProjectOwnersToContributors.new.up

    assert_equal 'contributor', owner_membership.reload.role
  end

  def test_existing_contributor_rows_are_untouched
    contributor_membership = ProjectMembership.create!(user: @user, project: @project, role: 'contributor')

    ConvertProjectOwnersToContributors.new.up

    assert_equal 'contributor', contributor_membership.reload.role
  end
end

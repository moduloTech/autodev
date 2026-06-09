# frozen_string_literal: true

require_relative '../rails_helper'

# Coverage for the PR2 additions to User: admin flag,
# active_for_authentication? override, visible_projects helper.
class UserAdminTest < ActiveSupport::TestCase
  setup do
    @admin = User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)
    @regular = User.create!(email: 'user@modulotech.fr', name: 'Reg')
    @p1 = Project.create!(gitlab_path: 'group/p1', slug: 'group__p1')
    @p2 = Project.create!(gitlab_path: 'group/p2', slug: 'group__p2')
  end

  def test_admin_predicate
    assert_predicate @admin, :admin?
    refute_predicate @regular, :admin?
  end

  def test_active_for_authentication_default_true
    assert_predicate @regular, :active_for_authentication?
  end

  def test_active_for_authentication_false_when_disabled_at_set
    @regular.update!(disabled_at: Time.current)

    refute_predicate @regular, :active_for_authentication?
  end

  def test_inactive_message_routes_to_access_revoked_when_disabled
    @regular.update!(disabled_at: Time.current)

    assert_equal :access_revoked, @regular.inactive_message
  end

  def test_visible_projects_returns_all_for_admin
    assert_equal [@p1, @p2].map(&:id).sort, @admin.visible_projects.pluck(:id).sort
  end

  def test_visible_projects_filters_by_membership_for_non_admin
    ProjectMembership.create!(user: @regular, project: @p1, role: 'contributor')

    assert_equal [@p1.id], @regular.visible_projects.pluck(:id)
  end

  def test_visible_projects_empty_for_user_without_memberships
    assert_empty @regular.visible_projects
  end
end

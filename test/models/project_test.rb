# frozen_string_literal: true

require_relative '../rails_helper'

class ProjectTest < ActiveSupport::TestCase
  def test_gitlab_path_and_slug_are_required
    refute_predicate Project.new(slug: 'group__bar'), :valid?
    refute_predicate Project.new(gitlab_path: 'group/bar'), :valid?
  end

  def test_gitlab_path_must_be_unique
    Project.create!(gitlab_path: 'group/foo', slug: 'group__foo')
    duplicate = Project.new(gitlab_path: 'group/foo', slug: 'other')

    refute_predicate duplicate, :valid?
    assert_includes duplicate.errors[:gitlab_path], 'has already been taken'
  end

  def test_slug_must_be_unique
    Project.create!(gitlab_path: 'group/foo', slug: 'group__foo')
    duplicate = Project.new(gitlab_path: 'group/other', slug: 'group__foo')

    refute_predicate duplicate, :valid?
    assert_includes duplicate.errors[:slug], 'has already been taken'
  end

  def test_default_locale_defaults_to_fr_and_validates_inclusion
    project = Project.create!(gitlab_path: 'g/x', slug: 'g__x')

    assert_equal 'fr', project.default_locale

    project.default_locale = 'de'

    refute_predicate project, :valid?
  end

  def test_owners_scope_returns_only_owner_role
    project    = Project.create!(gitlab_path: 'g/y', slug: 'g__y')
    contrib    = User.create!(email: 'c@m.fr', name: 'C')
    owner      = User.create!(email: 'o@m.fr', name: 'O')
    ProjectMembership.create!(user: contrib, project: project, role: ProjectMembership::ROLE_CONTRIBUTOR)
    ProjectMembership.create!(user: owner, project: project, role: ProjectMembership::ROLE_OWNER)

    assert_equal [owner], project.owners.to_a
    assert_equal 2, project.users.count
  end

  def test_destroying_project_cascades_app_commands_and_memberships
    project = Project.create!(gitlab_path: 'g/z', slug: 'g__z')
    user    = User.create!(email: 'd@m.fr', name: 'D')
    project.app_commands.create!(category: ProjectAppCommand::CATEGORY_SETUP, command: %w[bundle install])
    ProjectMembership.create!(user: user, project: project, role: ProjectMembership::ROLE_CONTRIBUTOR)

    project.destroy!

    assert_equal 0, ProjectAppCommand.count
    assert_equal 0, ProjectMembership.count
    # User row survives — membership is what cascades.
    assert_equal 1, User.count
  end
end

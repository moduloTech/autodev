# frozen_string_literal: true

require_relative '../rails_helper'

class UserTest < ActiveSupport::TestCase
  def test_email_is_required
    user = User.new(name: 'Marc')

    refute_predicate user, :valid?
    assert_includes user.errors[:email], "can't be blank"
  end

  def test_email_must_be_unique_case_insensitive
    User.create!(email: 'marc@modulotech.fr', name: 'Marc')
    duplicate = User.new(email: 'MARC@modulotech.fr', name: 'Marc 2')

    refute_predicate duplicate, :valid?
    assert_includes duplicate.errors[:email], 'has already been taken'
  end

  def test_locale_defaults_to_fr_and_validates_inclusion
    user = User.create!(email: 'a@b.com', name: 'A')

    assert_equal 'fr', user.locale

    user.locale = 'es'

    refute_predicate user, :valid?
    assert_includes user.errors[:locale], 'is not included in the list'
  end

  def test_microsoft_uid_unique_when_present_but_nullable
    User.create!(email: 'a@b.com', name: 'A', microsoft_uid: 'azure-oid-1')
    # Two NULL microsoft_uid rows are allowed — partial unique index.
    User.create!(email: 'b@b.com', name: 'B', microsoft_uid: nil)
    User.create!(email: 'c@b.com', name: 'C', microsoft_uid: nil)

    assert_raises(ActiveRecord::RecordNotUnique) do
      User.create!(email: 'd@b.com', name: 'D', microsoft_uid: 'azure-oid-1')
    end
  end

  def test_role_helpers_return_falsy_when_no_membership
    user    = User.create!(email: 'u@m.fr', name: 'U')
    project = Project.create!(gitlab_path: 'g/p', slug: 'g__p')

    assert_nil user.role_on(project)
    refute user.contributor_of?(project)
    refute user.owner_of?(project)
  end

  def test_contributor_membership_marks_user_as_contributor_only
    user    = User.create!(email: 'u@m.fr', name: 'U')
    project = Project.create!(gitlab_path: 'g/p', slug: 'g__p')
    ProjectMembership.create!(user: user, project: project, role: ProjectMembership::ROLE_CONTRIBUTOR)
    user.reload

    assert_equal ProjectMembership::ROLE_CONTRIBUTOR, user.role_on(project)
    assert user.contributor_of?(project)
    refute user.owner_of?(project)
  end

  def test_owner_is_also_contributor
    user    = User.create!(email: 'o@m.fr', name: 'O')
    project = Project.create!(gitlab_path: 'g/p2', slug: 'g__p2')
    ProjectMembership.create!(user: user, project: project, role: ProjectMembership::ROLE_OWNER)
    user.reload

    assert user.contributor_of?(project), 'owner inherits contributor capabilities'
    assert user.owner_of?(project)
  end
end

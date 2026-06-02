# frozen_string_literal: true

require_relative '../rails_helper'

class ProjectMembershipTest < ActiveSupport::TestCase
  setup do
    @user    = User.create!(email: 'u@m.fr', name: 'U')
    @project = Project.create!(gitlab_path: 'g/p', slug: 'g__p')
  end

  def test_role_must_be_contributor_or_owner
    pm = ProjectMembership.new(user: @user, project: @project, role: 'admin')

    refute_predicate pm, :valid?
    assert_includes pm.errors[:role], 'is not included in the list'
  end

  def test_one_membership_per_user_project_pair
    ProjectMembership.create!(user: @user, project: @project, role: 'contributor')
    duplicate = ProjectMembership.new(user: @user, project: @project, role: 'owner')

    refute_predicate duplicate, :valid?
    assert_includes duplicate.errors[:user_id], 'has already been taken'
  end

  def test_unique_constraint_enforced_at_db_level
    ProjectMembership.create!(user: @user, project: @project, role: 'contributor')
    # Bypass model validations to confirm the DB index also blocks duplicates
    # (catches an offline backfill / rake import skipping AR callbacks).
    assert_raises(ActiveRecord::RecordNotUnique) do
      ProjectMembership.new(user: @user, project: @project, role: 'owner').save!(validate: false)
    end
  end

  def test_belongs_to_user_and_project_required
    refute_predicate ProjectMembership.new(project: @project, role: 'contributor'), :valid?
    refute_predicate ProjectMembership.new(user: @user, role: 'contributor'), :valid?
  end
end

# frozen_string_literal: true

require_relative '../../rails_helper'

class GitlabMembershipSyncTest < ActiveSupport::TestCase # rubocop:disable Metrics/ClassLength
  # Minimal stub mimicking the gitlab gem's client surface that
  # `GitlabMembershipSync` consumes. `users(username:)` returns the
  # `@users_by_username` entry; `all_members(project_path)` wraps the
  # `@members_by_project_path` array in an object that responds to
  # `auto_paginate` exactly like `Gitlab::PaginatedResponse` does.
  class FakeGitlabClient
    attr_writer :users_by_username, :members_by_project_path

    def initialize
      @users_by_username = {}
      @members_by_project_path = {}
    end

    def users(options = {})
      @users_by_username.fetch(options[:username], [])
    end

    def all_members(project_path, _options = {})
      Paginated.new(@members_by_project_path.fetch(project_path, []))
    end

    Paginated = Struct.new(:items) do
      def auto_paginate
        items
      end
    end
  end

  def gl_user(id:, username:)
    Struct.new(:id, :username).new(id, username)
  end

  def gl_member(id:, access_level:)
    Struct.new(:id, :access_level).new(id, access_level)
  end

  setup do
    @client = FakeGitlabClient.new
    @user = User.create!(email: 'marc@modulotech.fr', name: 'Marc')
    @p1 = Project.create!(gitlab_path: 'group/p1', slug: 'group__p1')
    @p2 = Project.create!(gitlab_path: 'group/p2', slug: 'group__p2')
  end

  # ---- identity resolution ----------------------------------------

  def test_resolve_identity_uses_email_local_part
    @client.users_by_username = { 'marc' => [gl_user(id: 42, username: 'marc')] }
    @client.members_by_project_path = { 'group/p1' => [], 'group/p2' => [] }

    ::Autodev::GitlabMembershipSync.for_user!(@user, client: @client)

    assert_equal 42, @user.reload.gitlab_user_id
    assert_equal 'marc', @user.gitlab_username
  end

  def test_resolve_identity_honors_existing_gitlab_username_override
    @user.update!(gitlab_username: 'mleclercq')
    @client.users_by_username = { 'mleclercq' => [gl_user(id: 99, username: 'mleclercq')] }
    @client.members_by_project_path = { 'group/p1' => [], 'group/p2' => [] }

    ::Autodev::GitlabMembershipSync.for_user!(@user, client: @client)

    assert_equal 99, @user.reload.gitlab_user_id
  end

  def test_resolve_identity_raises_when_no_match
    @client.users_by_username = {}

    assert_raises(::Autodev::GitlabMembershipSync::UnresolvedGitlabIdentity) do
      ::Autodev::GitlabMembershipSync.for_user!(@user, client: @client)
    end
  end

  # ---- role mapping -----------------------------------------------

  # Autodev #38: the owner role is now 100% manual (cf. reconcile_memberships!
  # immunity tests below) — GitLab access_level no longer derives it. A
  # maintainer (or GitLab Owner, 50) lands as a plain contributor, same as
  # a developer/reporter.
  def test_maintainer_becomes_contributor
    setup_resolved_user(gitlab_user_id: 42)
    @client.members_by_project_path = {
      'group/p1' => [gl_member(id: 42, access_level: 40)],
      'group/p2' => []
    }

    ::Autodev::GitlabMembershipSync.for_user!(@user, client: @client)

    assert_equal 'contributor', @user.project_memberships.find_by(project: @p1).role
  end

  def test_developer_becomes_contributor
    setup_resolved_user(gitlab_user_id: 42)
    @client.members_by_project_path = {
      'group/p1' => [gl_member(id: 42, access_level: 30)],
      'group/p2' => []
    }

    ::Autodev::GitlabMembershipSync.for_user!(@user, client: @client)

    assert_equal 'contributor', @user.project_memberships.find_by(project: @p1).role
  end

  def test_reporter_becomes_contributor
    setup_resolved_user(gitlab_user_id: 42)
    @client.members_by_project_path = {
      'group/p1' => [gl_member(id: 42, access_level: 20)],
      'group/p2' => []
    }

    ::Autodev::GitlabMembershipSync.for_user!(@user, client: @client)

    assert_equal 'contributor', @user.project_memberships.find_by(project: @p1).role
  end

  def test_guest_yields_no_membership
    setup_resolved_user(gitlab_user_id: 42)
    @client.members_by_project_path = {
      'group/p1' => [gl_member(id: 42, access_level: 10)],
      'group/p2' => []
    }

    ::Autodev::GitlabMembershipSync.for_user!(@user, client: @client)

    assert_empty @user.project_memberships.where(project: @p1)
  end

  # ---- reconciliation ---------------------------------------------

  # Autodev #38: `contributor` is the only role the sync can still assign, so
  # a maintainer-level access bump on an existing contributor row is a no-op
  # (no `membership.role_changed` audit) — it stays `contributor` either way.
  def test_contributor_stays_contributor_on_access_level_bump
    setup_resolved_user(gitlab_user_id: 42)
    membership = ProjectMembership.create!(user: @user, project: @p1, role: 'contributor')
    @client.members_by_project_path = {
      'group/p1' => [gl_member(id: 42, access_level: 40)],
      'group/p2' => []
    }

    ::Autodev::GitlabMembershipSync.for_user!(@user, client: @client)

    assert_equal 'contributor', membership.reload.role
    assert_equal 0, AuditLog.where(action: 'membership.role_changed').count
  end

  def test_membership_revoke_deletes_row_and_records_audit
    setup_resolved_user(gitlab_user_id: 42)
    ProjectMembership.create!(user: @user, project: @p1, role: 'contributor')
    @client.members_by_project_path = { 'group/p1' => [], 'group/p2' => [] }

    ::Autodev::GitlabMembershipSync.for_user!(@user, client: @client)

    assert_empty ProjectMembership.where(user_id: @user.id)
    assert_equal 1, AuditLog.where(action: 'membership.revoked').count
  end

  # ---- owner immunity (Autodev #38) --------------------------------
  #
  # Owner is now a manual-only designation (cf. project_owners_controller_test.rb).
  # The sync must never touch an existing owner row, whatever GitLab reports.

  def test_owner_row_survives_when_gitlab_reports_contributor_level_access
    setup_resolved_user(gitlab_user_id: 42)
    membership = ProjectMembership.create!(user: @user, project: @p1, role: 'owner')
    @client.members_by_project_path = {
      'group/p1' => [gl_member(id: 42, access_level: 30)],
      'group/p2' => []
    }

    ::Autodev::GitlabMembershipSync.for_user!(@user, client: @client)

    assert_equal 'owner', membership.reload.role
    assert_equal 0, AuditLog.where(action: 'membership.role_changed').count
  end

  def test_owner_row_survives_when_gitlab_no_longer_lists_the_user
    setup_resolved_user(gitlab_user_id: 42)
    membership = ProjectMembership.create!(user: @user, project: @p1, role: 'owner')
    @client.members_by_project_path = { 'group/p1' => [], 'group/p2' => [] }

    ::Autodev::GitlabMembershipSync.for_user!(@user, client: @client)

    assert_predicate membership.reload, :persisted?
    assert_equal 'owner', membership.role
    assert_equal 0, AuditLog.where(action: 'membership.revoked').count
  end

  # ---- user lifecycle ---------------------------------------------

  def test_user_disabled_when_no_memberships_remain
    setup_resolved_user(gitlab_user_id: 42)
    @client.members_by_project_path = { 'group/p1' => [], 'group/p2' => [] }

    ::Autodev::GitlabMembershipSync.for_user!(@user, client: @client)

    assert_not_nil @user.reload.disabled_at
    assert_equal 1, AuditLog.where(action: 'user.disabled').count
  end

  def test_user_reactivated_when_access_restored
    setup_resolved_user(gitlab_user_id: 42, disabled_at: 1.day.ago)
    @client.members_by_project_path = {
      'group/p1' => [gl_member(id: 42, access_level: 30)],
      'group/p2' => []
    }

    ::Autodev::GitlabMembershipSync.for_user!(@user, client: @client)

    assert_nil @user.reload.disabled_at
    assert_equal 1, AuditLog.where(action: 'user.reactivated').count
  end

  def test_user_already_disabled_stays_disabled_silently_when_still_no_access
    setup_resolved_user(gitlab_user_id: 42, disabled_at: 1.day.ago)
    @client.members_by_project_path = { 'group/p1' => [], 'group/p2' => [] }

    ::Autodev::GitlabMembershipSync.for_user!(@user, client: @client)

    assert_not_nil @user.reload.disabled_at
    assert_equal 0, AuditLog.where(action: 'user.disabled').count
  end

  private

  def setup_resolved_user(gitlab_user_id:, disabled_at: nil)
    @user.update!(gitlab_user_id: gitlab_user_id, gitlab_username: 'marc',
                  disabled_at: disabled_at)
  end
end

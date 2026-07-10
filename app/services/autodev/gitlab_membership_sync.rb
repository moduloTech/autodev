# frozen_string_literal: true

module Autodev
  # GitLab-authoritative reconciliation of `project_memberships` (cf.
  # docs/users-rollout.md §3). For every user × every Project in the
  # local table, fetch the effective access_level from GitLab's
  # `/projects/:id/members/all` (group inheritance included) and:
  #
  # - level ≥ 20 (Reporter / Developer / Maintainer / Owner) → local role `contributor`
  # - level 10 (Guest) or none → no local membership
  #
  # ADD + REMOVE: a sync run reconciles the full set of `contributor` rows,
  # so revocations on GitLab propagate at the next sync.
  #
  # Owner (Autodev #38): NOT derived from GitLab anymore. It's a 100%
  # manual designation made from the project's Team tab
  # (ProjectOwnersController) — see `reconcile_memberships!` below, which
  # excludes `owner` rows entirely from this reconciliation (never
  # downgraded, never revoked). Rationale: mapping GitLab Maintainer (40)
  # straight to `owner` meant every maintainer on a project like PowerPanne
  # became an AutoSpec approver, which doesn't hold — approval rights are a
  # project-local decision, not a GitLab permission.
  #
  # Identity resolution: the GitLab user is looked up by username
  # derived from the email (`login@modulotech.fr` → `login`); the
  # actual GitLab username is then cached on the row. Exceptions get
  # an explicit override via `bin/rails autodev:link_user EMAIL=…
  # GITLAB_USERNAME=…`.
  #
  # Best-effort at the user level: in `for_all_users!`, failures on
  # one user are logged and the loop continues. At the controller
  # level (`Users::OmniauthCallbacksController`), an exception raised
  # here short-circuits the sign-in with a clean error message.
  class GitlabMembershipSync # rubocop:disable Metrics/ClassLength
    # GitLab access levels — see
    # https://docs.gitlab.com/api/access_requests/ for the canonical list.
    REPORTER_ACCESS_THRESHOLD = 20 # Reporter (20) + Developer (30) + Maintainer/Owner (40/50)

    class UnresolvedGitlabIdentity < StandardError; end
    class SyncFailed < StandardError; end

    def self.for_user!(user, **)
      new(**).for_user!(user)
    end

    def self.for_all_users!(**)
      new(**).for_all_users!
    end

    def initialize(client: nil, config: nil, logger: Rails.logger)
      @config = config || ::Web.config || {}
      @client = client
      @logger = logger
    end

    def for_user!(user)
      warn_if_no_projects
      resolve_gitlab_identity!(user) if user.gitlab_user_id.nil?
      desired = compute_desired_roles_for(user)
      reconcile_memberships!(user, desired)
      apply_active_status!(user, desired)
      user
    end

    def for_all_users!
      warn_if_no_projects
      User.find_each do |user|
        for_user!(user)
      rescue UnresolvedGitlabIdentity, SyncFailed => e
        @logger.warn("[gitlab_sync] skipping #{user.email}: #{e.class}: #{e.message}")
      end
    end

    private

    def client
      @client ||= ::GitlabHelpers.build_gitlab_client(@config['gitlab_url'], @config['gitlab_token'])
    end

    # Idempotent — logs once per sync run. Bobette hit this during the
    # alpha.6 verification: a fresh DB with no projects imported looks
    # identical to a healthy sync that simply produces zero memberships,
    # except every user ends up `disabled`. The warning makes the cause
    # impossible to miss.
    def warn_if_no_projects
      return if @warned_no_projects
      return if Project.exists?

      @warned_no_projects = true
      @logger.warn('[gitlab_sync] WARNING: `projects` table is empty — every user will be marked ' \
                   'disabled. Import the YAML config first (autodev:migrate_projects_from_yaml).')
    end

    # ---- identity resolution ---------------------------------------

    def resolve_gitlab_identity!(user)
      candidate = user.gitlab_username.presence || derive_username(user.email)
      raise UnresolvedGitlabIdentity, "cannot derive GitLab username for #{user.email}" if candidate.blank?

      gl_user = lookup_gitlab_user(candidate)
      if gl_user.nil?
        raise UnresolvedGitlabIdentity,
              "no GitLab user matches '#{candidate}' (override via " \
              "`autodev:link_user EMAIL=#{user.email} GITLAB_USERNAME=…`)"
      end

      user.update!(gitlab_user_id: gl_user.id, gitlab_username: gl_user.username)
    end

    def derive_username(email)
      return nil if email.blank? || !email.include?('@')

      email.split('@', 2).first.downcase
    end

    def lookup_gitlab_user(username)
      Array(client.users(username: username)).first
    rescue Gitlab::Error::ResponseError => e
      raise SyncFailed, "GitLab API while searching '#{username}': #{e.message}"
    end

    # ---- desired-state computation ---------------------------------

    def compute_desired_roles_for(user)
      project_access_map.each_with_object({}) do |(project_id, members), h|
        role = role_for_access_level(members[user.gitlab_user_id])
        h[project_id] = role if role
      end
    end

    # Memoized once per sync run — `for_all_users!` reuses the same
    # map across users so we hit GitLab N times (one per project), not
    # N × U times.
    def project_access_map
      @project_access_map ||= Project.find_each.to_h do |project|
        [project.id, fetch_project_members(project)]
      end
    end

    def fetch_project_members(project)
      members = Array(client.all_members(project.gitlab_path).auto_paginate)
      members.to_h { |m| [m.id, m.access_level] }
    rescue Gitlab::Error::ResponseError => e
      raise SyncFailed, "GitLab API while fetching members for #{project.gitlab_path}: #{e.message}"
    end

    def role_for_access_level(level)
      return nil if level.nil?
      return ::ProjectMembership::ROLE_CONTRIBUTOR if level >= REPORTER_ACCESS_THRESHOLD

      nil
    end

    # ---- reconciliation --------------------------------------------

    # `owner` rows are immune (Autodev #38): manually granted, so they're
    # excluded from `managed` up front and never appear on either side of
    # the create/change/revoke logic below — not downgraded when GitLab
    # reports lower (or no) access, not deleted when GitLab drops the user
    # entirely. Only `contributor` rows are GitLab-authoritative.
    def reconcile_memberships!(user, desired)
      existing = user.project_memberships.index_by(&:project_id)
      managed = existing.reject { |_project_id, membership| membership.role == ::ProjectMembership::ROLE_OWNER }

      desired.each { |project_id, role| reconcile_one!(user, project_id, role, existing, managed) }

      (managed.keys - desired.keys).each { |pid| revoke_membership!(managed[pid]) }
    end

    def reconcile_one!(user, project_id, role, existing, managed)
      membership = managed[project_id]
      if membership.nil?
        create_membership!(user, project_id, role) unless existing.key?(project_id)
      elsif membership.role != role
        change_role!(membership, role)
      end
    end

    def create_membership!(user, project_id, role)
      membership = ::ProjectMembership.create!(user_id: user.id, project_id: project_id, role: role)
      ::Audit.record!(
        resource: membership, action: 'membership.granted',
        payload: { user_id: user.id, project_id: project_id, role: role, source: 'gitlab_sync' }
      )
    end

    def change_role!(membership, role)
      from = membership.role
      membership.update!(role: role)
      ::Audit.record!(
        resource: membership, action: 'membership.role_changed',
        payload: { user_id: membership.user_id, project_id: membership.project_id,
                   from_role: from, to_role: role }
      )
    end

    def revoke_membership!(membership)
      # Record before destroy so `membership.id` is still alive when
      # Audit.record! reads it. AR's destroy can leave the in-memory id
      # either as-is or nilified depending on the version + callback
      # chain, so don't rely on the frozen object for the audit fields.
      ::Audit.record!(
        resource: membership, action: 'membership.revoked',
        payload: { user_id: membership.user_id, project_id: membership.project_id,
                   previous_role: membership.role, source: 'gitlab_sync' }
      )
      membership.destroy!
    end

    # ---- user lifecycle --------------------------------------------

    def apply_active_status!(user, desired)
      if desired.empty? && user.disabled_at.nil?
        user.update!(disabled_at: Time.current)
        ::Audit.record!(resource: user, action: 'user.disabled', payload: { reason: 'no_memberships' })
      elsif desired.any? && user.disabled_at.present?
        user.update!(disabled_at: nil)
        ::Audit.record!(resource: user, action: 'user.reactivated',
                        payload: { reason: 'gitlab_sync_restored_access' })
      end
    end
  end
end

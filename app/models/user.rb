# frozen_string_literal: true

# Microsoft 365 SSO user (cf. autodev/docs/autospec.md §A, §J,
# docs/users-rollout.md §2).
#
# Step 3 plugged Devise modules for tracking + omniauth.
# PR2 of the users-rollout chantier extends the row with the
# admin flag (platform-wide), the GitLab identity cache
# (`gitlab_user_id` / `gitlab_username`), and the soft-disable
# stamp (`disabled_at`). No `:database_authenticatable` — passwords
# don't exist in this app, only Entra ID tokens.
class User < ApplicationRecord
  VALID_LOCALES = %w[fr en].freeze

  devise :trackable, :omniauthable, omniauth_providers: %i[entra_id]

  has_many :project_memberships, dependent: :destroy
  has_many :projects, through: :project_memberships
  has_many :audit_logs_as_actor, class_name: 'AuditLog', foreign_key: :actor_id,
                                 inverse_of: :actor, dependent: :nullify
  has_many :autospec_drafts, dependent: :destroy
  has_many :autospec_approvals_cast, class_name: 'AutospecApproval', dependent: :destroy

  validates :email, presence: true, uniqueness: { case_sensitive: false }
  validates :locale, inclusion: { in: VALID_LOCALES }

  # Find-or-create the user matching an Entra ID auth hash. Lookup is on
  # `microsoft_uid` (Azure subject claim — stable per-tenant). On first
  # sign-in we also stamp `email` / `name` from the token; on subsequent
  # sign-ins we refresh them in case the user renamed in Entra. The
  # GitLab-side identity resolution + membership sync is intentionally
  # NOT done here — `Users::OmniauthCallbacksController#entra_id` runs
  # it after this returns, so a sync failure can short-circuit the
  # sign-in with a clean message instead of partial state.
  def self.from_omniauth(auth)
    user = find_by(microsoft_uid: auth.uid)
    # If the row was seeded with an email but no microsoft_uid (e.g.
    # `autodev:seed_admin EMAIL=…` ran before the user's first SSO),
    # attach the Entra uid to the existing row instead of creating a
    # duplicate that would collide on the unique-email index. Email
    # match is case-insensitive — mirrors the `case_sensitive: false`
    # uniqueness validation.
    user ||= find_by_email_ci(auth.info&.email)
    user ||= new
    user.microsoft_uid ||= auth.uid
    apply_omniauth_info!(user, auth.info)
    user.save!
    user
  end

  def self.find_by_email_ci(email)
    return nil if email.blank?

    where('LOWER(email) = ?', email.downcase).first
  end
  private_class_method :find_by_email_ci

  def self.apply_omniauth_info!(user, info)
    return if info.nil?

    user.email = info.email if info.respond_to?(:email) && info.email.present?
    user.name  = info.name  if info.respond_to?(:name)  && info.name.present?
  end
  private_class_method :apply_omniauth_info!

  def role_on(project)
    project_memberships.find_by(project: project)&.role
  end

  # contributor OR owner — owner inherits contributor capabilities (autospec §J).
  def contributor_of?(project)
    role_on(project).present?
  end

  def owner_of?(project)
    role_on(project) == ProjectMembership::ROLE_OWNER
  end

  # Devise hook: a non-nil disabled_at flips the user inactive so the
  # next sign-in is rejected. The row itself is preserved (audit_log
  # entries continue to reference it) — soft delete, not destroy.
  def active_for_authentication?
    super && disabled_at.nil?
  end

  def inactive_message
    disabled_at.present? ? :access_revoked : super
  end

  # Projects this user is allowed to see in the dashboard. Admins see
  # everything; everyone else only sees projects where they have a
  # membership. Used by the dashboard / issues / projects controllers
  # once PR3 turns on per-route gating.
  def visible_projects
    admin? ? Project.all : projects
  end
end

# frozen_string_literal: true

# Microsoft 365 SSO user (cf. autodev/docs/autospec.md §A, §J).
#
# Step 3 plugs Devise modules for tracking + omniauth. No
# `:database_authenticatable` — passwords don't exist in this app, only
# Entra ID tokens. `User.from_omniauth` is the only path that creates rows.
class User < ApplicationRecord
  VALID_LOCALES = %w[fr en].freeze

  devise :trackable, :omniauthable, omniauth_providers: %i[entra_id]

  has_many :project_memberships, dependent: :destroy
  has_many :projects, through: :project_memberships

  validates :email, presence: true, uniqueness: { case_sensitive: false }
  validates :locale, inclusion: { in: VALID_LOCALES }

  # Find-or-create the user matching an Entra ID auth hash. Lookup is on
  # `microsoft_uid` (Azure subject claim — stable per-tenant). On first
  # sign-in we also stamp `email` / `name` from the token; on subsequent
  # sign-ins we refresh them in case the user renamed in Entra.
  def self.from_omniauth(auth)
    user = find_or_initialize_by(microsoft_uid: auth.uid)
    apply_omniauth_info!(user, auth.info)
    user.save!
    user
  end

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
end

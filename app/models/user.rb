# frozen_string_literal: true

# Microsoft 365 SSO user (cf. autodev/docs/autospec.md §A, §J).
#
# Step 2: schema + associations + role helpers, nothing reads/writes yet.
# Step 3 will plug Devise + omniauth Azure AD onto this same row.
class User < ApplicationRecord
  VALID_LOCALES = %w[fr en].freeze

  has_many :project_memberships, dependent: :destroy
  has_many :projects, through: :project_memberships

  validates :email, presence: true, uniqueness: { case_sensitive: false }
  validates :locale, inclusion: { in: VALID_LOCALES }

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

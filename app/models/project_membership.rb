# frozen_string_literal: true

# (user, project) pair with a role (cf. autodev/docs/autospec.md §J).
#
# Owner = contributor + draft-approval + "send to AutoDev" gate. One row per
# pair — role changes are an UPDATE, enforced by the unique index on
# (user_id, project_id).
class ProjectMembership < ApplicationRecord
  ROLE_CONTRIBUTOR = 'contributor'
  ROLE_OWNER       = 'owner'
  ROLES            = [ROLE_CONTRIBUTOR, ROLE_OWNER].freeze

  belongs_to :user
  belongs_to :project

  validates :role, inclusion: { in: ROLES }
  validates :user_id, uniqueness: { scope: :project_id }
end

# frozen_string_literal: true

# A GitLab project tracked by Autodev (cf. autodev/docs/autospec.md §A).
#
# Step 2: empty during phase B. Phase C's `autodev:migrate_projects_from_yaml`
# rake (autospec §H) populates this from `~/.autodev/config.yml`'s `projects:`
# block, after which the legacy YAML branch in `lib/autodev/poller.rb` is
# deleted.
class Project < ApplicationRecord
  VALID_LOCALES = %w[fr en].freeze

  has_many :app_commands, class_name: 'ProjectAppCommand', dependent: :destroy
  has_many :project_memberships, dependent: :destroy
  has_many :users, through: :project_memberships
  has_many :owners, -> { where(project_memberships: { role: ProjectMembership::ROLE_OWNER }) },
           through: :project_memberships, source: :user

  validates :gitlab_path, presence: true, uniqueness: true
  validates :slug, presence: true, uniqueness: true
  validates :default_locale, inclusion: { in: VALID_LOCALES }
end

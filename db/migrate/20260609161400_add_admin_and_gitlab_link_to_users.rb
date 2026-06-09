# frozen_string_literal: true

# PR2 of the users-rollout chantier (cf. docs/users-rollout.md §6).
#
# - `admin`: platform-wide flag. An admin sees every project regardless
#   of project_memberships and can access the read-only `/admin/users`
#   page. NOT touched by the GitLab sync — promotion happens via the
#   `autodev:seed_admin` rake task or `bin/rails console`.
# - `gitlab_user_id` / `gitlab_username`: cached identity of the user on
#   the GitLab side. Resolved at first sync from the email's local-part
#   (`login@modulotech.fr` → username `login`); exceptions get a manual
#   override via `autodev:link_user EMAIL=… GITLAB_USERNAME=…`.
# - `disabled_at`: posted by the sync when a user has no membership ≥
#   Reporter on any tracked project. `User#active_for_authentication?`
#   returns false while non-nil → Devise refuses the next sign-in.
class AddAdminAndGitlabLinkToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :admin,           :boolean, null: false, default: false
    add_column :users, :gitlab_user_id,  :integer
    add_column :users, :gitlab_username, :string
    add_column :users, :disabled_at,     :datetime

    add_index :users, :gitlab_user_id, unique: true,
                                       where: 'gitlab_user_id IS NOT NULL',
                                       name: 'idx_users_gitlab_user_id'
  end
end

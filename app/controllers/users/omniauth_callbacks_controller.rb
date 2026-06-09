# frozen_string_literal: true

# `config/application.rb` skips `Bundler.require(*Rails.groups)` and the
# Devise engine adds `app/controllers/devise/*` to autoload paths via its
# Railtie — but with our pared-down railtie set the engine isn't fully
# wired. Require the parent controller explicitly so the subclass below
# resolves at boot.
require "#{Gem::Specification.find_by_name('devise').gem_dir}/app/controllers/devise_controller"
require "#{Gem::Specification.find_by_name('devise').gem_dir}/app/controllers/devise/omniauth_callbacks_controller"

module Users
  # Entra ID OAuth2 callback handler (cf. docs/autospec.md §A,
  # docs/users-rollout.md §3, §4).
  #
  # The omniauth middleware (configured in `config/initializers/devise.rb`)
  # exchanges the authorization code for tokens, builds the auth hash, then
  # POSTs to `/users/auth/entra_id/callback` which Devise routes here.
  #
  # Flow per PR2 of the users-rollout chantier:
  #
  #  1. `User.from_omniauth` find-or-creates the row by Entra ID `oid`.
  #  2. `Autodev::GitlabMembershipSync.for_user!` synchronously reconciles
  #     project_memberships against GitLab — this also resolves the
  #     `gitlab_user_id` on first sign-in.
  #  3. Sign-in: Devise checks `active_for_authentication?`, which
  #     consults `disabled_at` (set by the sync when the user has no
  #     membership ≥ Reporter).
  #
  # Failure modes:
  #
  #  - `UnresolvedGitlabIdentity` (no GitLab user matches the username
  #    derived from email): if the row was just created, destroy it so
  #    a later retry with a manual link starts clean; otherwise the row
  #    stays but sign-in is refused.
  #  - `SyncFailed` (GitLab API down): existing users sign in with their
  #    cached memberships; brand-new users get rolled back so we don't
  #    leave a half-provisioned account behind.
  class OmniauthCallbacksController < Devise::OmniauthCallbacksController
    def entra_id
      user = User.from_omniauth(auth)
      was_new = user.previously_new_record?
      ::Autodev::GitlabMembershipSync.for_user!(user)
      sign_in_and_redirect(user, event: :authentication)
    rescue ::Autodev::GitlabMembershipSync::UnresolvedGitlabIdentity => e
      handle_unresolved_identity(user, e, was_new: was_new)
    rescue ::Autodev::GitlabMembershipSync::SyncFailed => e
      handle_sync_failed(user, e, was_new: was_new)
    end

    def failure
      redirect_to root_path, alert: failure_message
    end

    private

    def auth
      request.env['omniauth.auth']
    end

    def handle_unresolved_identity(user, error, was_new:)
      Rails.logger.warn("[omniauth] unresolved GitLab identity for #{user&.email}: #{error.message}")
      user&.destroy if was_new
      redirect_to root_path,
                  alert: I18n.t('devise.failure.gitlab_identity_unresolved',
                                default: "We couldn't link your account to GitLab. Contact an admin.")
    end

    def handle_sync_failed(user, error, was_new:)
      Rails.logger.warn("[omniauth] gitlab sync failed for #{user&.email}: #{error.message}")
      if was_new
        user&.destroy
        redirect_to root_path,
                    alert: I18n.t('devise.failure.gitlab_unavailable',
                                  default: 'GitLab is unavailable right now. Please try again later.')
      else
        sign_in_and_redirect(user, event: :authentication)
      end
    end
  end
end

# frozen_string_literal: true

module Autodev
  # Single home for the imperative one-shot commands that ops needs to run
  # outside the supervisor's normal lifecycle (cf. docs/users-rollout.md §5).
  # Called both from `bin/autodev` (CLI flags, alpha.7+) and from the
  # `lib/tasks/autodev.rake` wrappers — so the behaviour stays identical
  # whether you run it from a Brew install or a `bin/rails runner` shell.
  #
  # Each method returns a short summary string suitable for `puts`-ing
  # straight to stdout; nothing here writes directly to $stdout so callers
  # are free to redirect / capture as they see fit.
  module OpsCommands
    module_function

    def seed_admin(email:)
      user = User.find_or_initialize_by(email: email)
      user.name ||= email.split('@', 2).first
      user.admin = true
      user.save!(validate: false)
      Audit.record!(resource: user, action: 'user.created',
                    payload: { source: 'seed_admin', email: email })
      "[autodev:seed_admin] #{user.email} (id=#{user.id}, admin=true)"
    end

    def sync_memberships(logger: Rails.logger)
      summary = { synced: 0, skipped: 0, errors: [] }
      User.find_each do |user|
        GitlabMembershipSync.for_user!(user, logger: logger)
        summary[:synced] += 1
      rescue GitlabMembershipSync::UnresolvedGitlabIdentity,
             GitlabMembershipSync::SyncFailed => e
        summary[:skipped] += 1
        summary[:errors] << "#{user.email}: #{e.class.name.split('::').last}: #{e.message}"
      end
      format_sync_summary(summary)
    end

    def link_user(email:, gitlab_username:)
      user = User.find_by!(email: email)
      user.update!(gitlab_username: gitlab_username, gitlab_user_id: nil)
      "[autodev:link_user] #{user.email} → #{gitlab_username} (gitlab_user_id will resolve at next sync)"
    end

    def format_sync_summary(summary)
      lines = ["[autodev:sync_memberships] #{summary.slice(:synced, :skipped).inspect}"]
      summary[:errors].each { |e| lines << "  - #{e}" }
      lines.join("\n")
    end
    private_class_method :format_sync_summary
  end
end

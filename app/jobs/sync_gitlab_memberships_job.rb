# frozen_string_literal: true

# Daily reconciliation of all `project_memberships` against GitLab.
# Scheduled at 03:00 by `config/recurring.yml`. Picks up revocations
# and access-level changes that happen between two logins of a user
# (the omniauth callback runs the same `for_user!` path per-user on
# sign-in for the immediate case).
#
# Per-user failures inside `for_all_users!` are caught + logged, so
# one broken user never aborts the run.
class SyncGitlabMembershipsJob < ApplicationJob
  queue_as :default

  def perform
    wrapped_logger = ::Autodev::JobLogger.new(logger)
    ::Autodev::GitlabMembershipSync.for_all_users!(logger: wrapped_logger)
  end
end

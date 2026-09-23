# frozen_string_literal: true

# Hourly refresh of every `Project.briefing_text` via
# `Autospec::ProjectBriefer`. Wired in `config/recurring.yml`. Each
# project is refreshed sequentially within one job run; the briefer
# caps each danger-claude call at `DANGER_CLAUDE_TIMEOUT` (10 minutes),
# so the worst-case worker occupancy is bounded by the project count.
#
# Per-project failures don't stop the run: every external call inside
# `ProjectBriefer#refresh!` (git, danger-claude, a spawn that cannot
# happen) raises RefreshFailed AND stores the message on
# `Project.briefing_error`, which `HealthReport`'s `project_briefings`
# card surfaces once a briefing goes stale. We catch + log here so the
# next project still runs. Anything else is a bug and deliberately
# stops the job, so it lands in Solid Queue's failed executions
# (Autodev #117 — before it, a failed clone surfaced as an ENOENT and
# took the projects after it down with it).
class RefreshProjectBriefingsJob < ApplicationJob
  queue_as :default

  def perform
    Project.find_each do |project|
      refresh_one(project)
    end
  end

  private

  def refresh_one(project)
    Autospec::ProjectBriefer.new(project).refresh!
    logger.info("Refreshed briefing for #{project.gitlab_path}")
  rescue Autospec::ProjectBriefer::RefreshFailed => e
    logger.warn("Briefing refresh failed for #{project.gitlab_path}: #{e.message}")
  end
end

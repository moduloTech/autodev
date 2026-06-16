# frozen_string_literal: true

# Hourly refresh of every `Project.briefing_text` via
# `Autospec::ProjectBriefer`. Wired in `config/recurring.yml`. Each
# project is refreshed sequentially within one job run — typical
# tenant has 10-20 projects + the briefer caps each refresh at
# 5 minutes, so the worst-case worker occupancy is bounded.
#
# Per-project failures don't stop the run: `ProjectBriefer#refresh!`
# raises RefreshFailed on any error path AND stores the message on
# `Project.briefing_error` for surfacing. We catch + log here so the
# next project still runs.
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

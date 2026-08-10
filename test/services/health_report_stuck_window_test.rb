# frozen_string_literal: true

require_relative '../rails_helper'

# How the stuck-issues window is sized (Autodev #50).
#
# The window must clear the longest a live worker can legitimately go quiet:
# one danger-claude call (dc_timeout, bounded per call by the DangerClaudeRunner
# heartbeat) or one post_completion command (post_completion_timeout, which gets
# no heartbeat — it is not a danger-claude call). Both are per-project, so the
# window is sized on the widest value in play, doubled for margin.
#
# Getting this wrong is not a monitoring nit: DormantAudit#active_window reads
# the same method and repositions rows by update_all, outside the concurrency
# lock that serialises IssueProcessJob.
class HealthReportStuckWindowTest < ActiveSupport::TestCase
  BASE = Autodev::HealthReport::STUCK_ACTIVE_AFTER # 7200
  CONFIG = { 'poll_interval' => 300 }.freeze

  def window(config: CONFIG)
    Autodev::HealthReport.new(config: config).stuck_active_after
  end

  def project(**attrs)
    Project.create!({ gitlab_path: 'group/proj', slug: 'group__proj' }.merge(attrs))
  end

  # 2 × the baked dc_timeout default (1800) is 3600, under the floor — so the
  # default configuration behaves exactly as it did before this change.
  test 'defaults to the baked floor' do
    assert_equal BASE, window
  end

  test 'derives from a project dc_timeout that exceeds the floor' do
    project(dc_timeout: 5400)

    assert_equal 10_800, window
  end

  test 'derives from a project post_completion_timeout' do
    project(post_completion: ['deploy.sh'], post_completion_timeout: 5400)

    assert_equal 10_800, window
  end

  # A project configured in YAML but not yet imported into the projects table is
  # still live config: IssueProcessJob falls back to it.
  test 'counts a YAML-only project' do
    config = CONFIG.merge('projects' => [{ 'path' => 'group/yaml', 'dc_timeout' => 5400 }])

    assert_equal 10_800, window(config: config)
  end

  test 'takes the widest value when several projects configure one' do
    project(dc_timeout: 3600)
    Project.create!(gitlab_path: 'group/other', slug: 'group__other', dc_timeout: 5400)

    assert_equal 10_800, window
  end

  # An explicit setting is a floor, not a ceiling: an operator can widen the
  # window but cannot configure it into incoherence with dc_timeout.
  test 'an explicit setting wider than the derived value wins' do
    config = CONFIG.merge('monitoring' => { 'stuck_active_after_seconds' => 20_000 })

    assert_equal 20_000, window(config: config)
  end

  test 'an explicit setting narrower than the derived value loses' do
    project(dc_timeout: 5400)
    config = CONFIG.merge('monitoring' => { 'stuck_active_after_seconds' => 3600 })

    assert_equal 10_800, window(config: config)
  end

  # The check reports the window it used, so the effective value is visible
  # rather than implicit when a derived floor overrode the setting.
  test 'the stuck_issues check reports the effective window' do
    project(dc_timeout: 5400)
    check = Autodev::HealthReport.new(config: CONFIG).check(:stuck_issues)[:checks][:stuck_issues]

    assert_equal 10_800, check[:meta][:window_seconds]
  end

  # The widened window is load-bearing, not cosmetic: a row silent 2.5h ago
  # would already have tripped the old 2h (7200s) floor, but is well inside
  # this project's derived 3h window, so it must not be flagged.
  test 'a row silent for less than the derived window is not stuck' do
    project(dc_timeout: 5400) # window 10800s = 3h
    Issue.create!(project_path: 'group/proj', issue_iid: 700, status: 'implementing',
                  created_at: 2.5.hours.ago)

    check = Autodev::HealthReport.new(config: CONFIG).check(:stuck_issues)[:checks][:stuck_issues]

    assert_equal :ok, check[:status]
  end
end

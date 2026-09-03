# frozen_string_literal: true

require_relative '../rails_helper'

# Autodev::HealthReport — the passive health snapshot behind /healthz and
# /admin/health. SolidQueue tables don't exist in the test DB (auto_migrate
# skips test env), so the workers/queue/database checks degrade to :down via
# the safe_check rescue; we stub those when asserting the rollup and exercise
# the DB-backed checks (poller/claude_usage/issues_error) with real rows.
class HealthReportTest < ActiveSupport::TestCase # rubocop:disable Metrics/ClassLength
  CONFIG = { 'poll_interval' => 300, 'monitoring' => { 'poll_stale_factor' => 3 } }.freeze

  def poller_event(age_seconds, usage_ok: true)
    ActivityEvent.create!(
      issue_id: nil, kind: 'poller', level: usage_ok ? 'info' : 'warn',
      payload_json: JSON.generate(event: 'cycle_complete', usage_ok: usage_ok),
      created_at: Time.now.utc - age_seconds
    )
  end

  def report(**)
    Autodev::HealthReport.new(config: CONFIG, **)
  end

  test 'poller ok when heartbeat is recent' do
    poller_event(60)

    assert_equal :ok, report(poller_expected: true).check(:poller)[:status]
  end

  test 'poller down when heartbeat is stale' do
    poller_event(5_000) # > 900s floor

    assert_equal :down, report(poller_expected: true).check(:poller)[:status]
  end

  test 'poller ok (disabled) when no heartbeat and not expected (dev)' do
    assert_equal :ok, report(poller_expected: false).check(:poller)[:status]
  end

  test 'poller down when no heartbeat but expected (prod)' do
    assert_equal :down, report(poller_expected: true).check(:poller)[:status]
  end

  # Since Autodev #46 the check reads Autodev::UsageGate's state (written at
  # probe time, before the passes run) rather than the heartbeat (written at
  # cycle end) — same envelope, fresher source.
  def usage_event(available:, age_seconds: 0)
    ActivityEvent.create!(
      issue_id: nil, kind: 'usage', level: available ? 'info' : 'warn',
      payload_json: JSON.generate(available: available),
      created_at: Time.now.utc - age_seconds
    )
  end

  test 'claude_usage warn when the last probe found the quota exhausted' do
    usage_event(available: false)

    assert_equal :warn, report.check(:claude_usage)[:status]
  end

  test 'claude_usage ok when the last probe found the quota available' do
    usage_event(available: true)

    assert_equal :ok, report.check(:claude_usage)[:status]
  end

  test 'claude_usage ok when nothing was ever probed' do
    assert_equal :ok, report.check(:claude_usage)[:status]
  end

  # A stale verdict must not keep the page red forever after the poller stops —
  # the poller check is what reports that.
  test 'claude_usage ok when the verdict is stale' do
    usage_event(available: false, age_seconds: 5_000)

    assert_equal :ok, report.check(:claude_usage)[:status]
  end

  test 'issues_error warn when an issue is in error' do
    Issue.create!(project_path: 'group/p', issue_iid: 4242, status: 'error')

    assert_equal :warn, report.check(:issues_error)[:status]
  end

  test 'issues_error ok when no issue is in error' do
    assert_equal :ok, report.check(:issues_error)[:status]
  end

  test 'unknown check raises ArgumentError' do
    assert_raises(ArgumentError) { report.check(:nope) }
  end

  test 'a raising check degrades to down rather than blowing up' do
    # workers touches SolidQueue, whose table is absent in the test DB.
    assert_equal :down, report.check(:workers)[:status]
  end

  test 'overall status is the worst severity across checks' do
    poller_event(5_000) # poller -> down
    healthy = { status: :ok, detail: 'stub', meta: {} }
    rep = report(poller_expected: true)

    result = rep.stub(:check_workers, healthy) do
      rep.stub(:check_queue, healthy) do
        rep.stub(:check_database, healthy) { rep.call }
      end
    end

    assert_equal :down, result[:status]
    assert_equal %i[poller workers queue claude_usage issues_error mr_review review_skill
                    mr_review_token stuck_issues database migrations gitlab_requests],
                 result[:checks].keys
  end

  # --- migrations (Autodev #55) -------------------------------------------
  #
  # The check reads Autodev::MigrationStatus.pending, a set difference between the
  # migration files and schema_migrations. In this environment the real answer is
  # non-empty — test/rails_helper.rb migrates the primary in-memory DB but never
  # the queue one — so both arms are asserted against a stubbed answer. That the
  # *primary* arm reads empty on a migrated DB is pinned in
  # test/services/autodev/migration_status_test.rb, against the real thing.

  test 'migrations ok when every migration is applied' do
    Autodev::MigrationStatus.stub(:pending, {}) do
      assert_equal :ok, report.check(:migrations)[:status]
    end
  end

  # down, not warn: /healthz answers 503 only on a real outage, and an incomplete
  # schema is one — Project#to_project_config raises NoMethodError on every job.
  test 'migrations down when a migration is unapplied, with the versions in meta' do
    Autodev::MigrationStatus.stub(:pending, { 'primary' => [20_260_810_000_001] }) do
      check = report.check(:migrations)[:checks][:migrations]

      assert_equal :down, check[:status]
      assert_equal '20260810000001', check[:meta][:pending_primary]
    end
  end

  # --- stuck_issues -------------------------------------------------------

  test 'stuck_issues ok when there are no monitored issues' do
    assert_equal :ok, report.check(:stuck_issues)[:status]
  end

  test 'stuck_issues warn for a pending issue older than the poll-stale window' do
    # poll_stale_after = max(300*3, 900) = 900s; created 2000s ago, no activity.
    Issue.create!(project_path: 'group/p', issue_iid: 700, status: 'pending',
                  created_at: Time.now.utc - 2_000)

    check = report.check(:stuck_issues)

    assert_equal :warn, check[:status]
    assert_equal 1, check[:checks][:stuck_issues][:meta][:count]
  end

  test 'stuck_issues ok for a freshly created pending issue' do
    Issue.create!(project_path: 'group/p', issue_iid: 701, status: 'pending',
                  created_at: Time.now.utc - 60)

    assert_equal :ok, report.check(:stuck_issues)[:status]
  end

  test 'stuck_issues uses recent activity, not creation time, for an active issue' do
    # Old creation but recent activity ⇒ a live long danger-claude run, not stuck.
    issue = Issue.create!(project_path: 'group/p', issue_iid: 702, status: 'implementing',
                          created_at: Time.now.utc - 100_000)
    ActivityEvent.create!(issue_id: issue.id, kind: 'danger_claude', level: 'info',
                          payload_json: '{}', created_at: Time.now.utc - 60)

    assert_equal :ok, report.check(:stuck_issues)[:status]
  end

  test 'stuck_issues warn for an active issue with stale activity (dead worker)' do
    issue = Issue.create!(project_path: 'group/p', issue_iid: 703, status: 'implementing',
                          created_at: Time.now.utc - 100_000)
    ActivityEvent.create!(issue_id: issue.id, kind: 'danger_claude', level: 'info',
                          payload_json: '{}', created_at: Time.now.utc - 10_000) # > 7200s

    assert_equal :warn, report.check(:stuck_issues)[:status]
  end

  test 'stuck_issues ignores terminal and human-wait states' do
    Issue.create!(project_path: 'group/p', issue_iid: 704, status: 'done',
                  created_at: Time.now.utc - 100_000)
    Issue.create!(project_path: 'group/p', issue_iid: 705, status: 'needs_clarification',
                  created_at: Time.now.utc - 100_000)
    Issue.create!(project_path: 'group/p', issue_iid: 706, status: 'checking_pipeline',
                  created_at: Time.now.utc - 100_000)

    assert_equal :ok, report.check(:stuck_issues)[:status]
  end
end

# frozen_string_literal: true

require_relative '../rails_helper'

# Autodev::HealthReport — the passive health snapshot behind /healthz and
# /admin/health. SolidQueue tables don't exist in the test DB (auto_migrate
# skips test env), so the workers/queue/database checks degrade to :down via
# the safe_check rescue; we stub those when asserting the rollup and exercise
# the DB-backed checks (poller/claude_usage/issues_error) with real rows.
class HealthReportTest < ActiveSupport::TestCase
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

  test 'claude_usage warn when the last poll had usage exhausted' do
    poller_event(60, usage_ok: false)

    assert_equal :warn, report.check(:claude_usage)[:status]
  end

  test 'claude_usage ok when the last poll had usage available' do
    poller_event(60, usage_ok: true)

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
    assert_equal %i[poller workers queue claude_usage issues_error database], result[:checks].keys
  end
end

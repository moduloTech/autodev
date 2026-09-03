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
  # cycle end) — same envelope, fresher source. `status` defaults from
  # `available` (Autodev #108's real vocabulary: `available`/`quota_exhausted`)
  # so every pre-existing call site keeps modelling exactly what it always did;
  # a call site testing one of the other four verdicts passes `status:`
  # explicitly.
  def usage_event(available:, status: nil, diagnostic: nil, age_seconds: 0)
    status ||= available ? 'available' : 'quota_exhausted'
    payload = { available: available, status: status }
    payload[:diagnostic] = diagnostic if diagnostic
    ActivityEvent.create!(
      issue_id: nil, kind: 'usage', level: available ? 'info' : 'warn',
      payload_json: JSON.generate(payload),
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

  # Autodev #108: claude_usage is scoped to the quota alone. A tool fault is
  # not a property of the quota — it has its own card, danger_claude, below.
  test 'claude_usage ok when the fault is an authentication refusal, not the quota' do
    usage_event(available: false, status: 'auth_refused')

    assert_equal :ok, report.check(:claude_usage)[:status]
  end

  test 'claude_usage ok when the fault is a missing binary' do
    usage_event(available: false, status: 'binary_missing')

    assert_equal :ok, report.check(:claude_usage)[:status]
  end

  test 'claude_usage ok when the fault is unrecognised (broken)' do
    usage_event(available: false, status: 'broken', diagnostic: 'boom')

    assert_equal :ok, report.check(:claude_usage)[:status]
  end

  # --- danger_claude (Autodev #108) ---------------------------------------
  #
  # The probe that already exercises the whole danger-claude chain kept only
  # one boolean; this card keeps the causes that boolean discarded. `down`
  # (not `warn`, unlike every other secondary check here bar `migrations`):
  # a danger-claude that cannot run stops implementation, review AND
  # discussion fixing alike, so /healthz must page on it.

  test 'danger_claude ok when nothing was ever probed' do
    assert_equal :ok, report.check(:danger_claude)[:status]
  end

  test 'danger_claude ok when the last probe succeeded' do
    usage_event(available: true)

    assert_equal :ok, report.check(:danger_claude)[:status]
  end

  # An exhausted quota is not a fault of the tool.
  test 'danger_claude ok when the quota is exhausted' do
    usage_event(available: false, status: 'quota_exhausted')

    assert_equal :ok, report.check(:danger_claude)[:status]
  end

  test 'danger_claude ok when the probe itself could not answer (unknown)' do
    usage_event(available: true, status: 'unknown')

    assert_equal :ok, report.check(:danger_claude)[:status]
  end

  test 'danger_claude down when the credential is refused, naming the cause' do
    usage_event(available: false, status: 'auth_refused')
    check = report.check(:danger_claude)[:checks][:danger_claude]

    assert_equal :down, check[:status]
    assert_includes check[:detail], 'authenticate'
  end

  test 'danger_claude down when the binary is missing, naming the cause' do
    usage_event(available: false, status: 'binary_missing')
    check = report.check(:danger_claude)[:checks][:danger_claude]

    assert_equal :down, check[:status]
    assert_includes check[:detail], 'not found on PATH'
  end

  # `broken` is the catch-all for any non-zero exit matching neither the quota
  # nor the auth signature, so one observation may be a container hiccup. It
  # warns first and pages on the second consecutive probe (alpha-53 review,
  # G5) — the same calibration `mr_review`'s thresholds got in Autodev #60.
  # `auth_refused` / `binary_missing` are deterministic and still page at
  # once, asserted above.
  test 'danger_claude warns on a single broken probe, quoting the diagnostic' do
    usage_event(available: false, status: 'broken', diagnostic: 'v1.54/volumes/danger-claude 500')
    check = report.check(:danger_claude)[:checks][:danger_claude]

    assert_equal :warn, check[:status]
    assert_includes check[:detail], 'v1.54/volumes/danger-claude 500'
    assert_equal 'v1.54/volumes/danger-claude 500', check[:meta][:diagnostic]
  end

  test 'danger_claude down on the second consecutive broken probe' do
    usage_event(available: false, status: 'broken', diagnostic: 'docker 500', age_seconds: 30)
    usage_event(available: false, status: 'broken', diagnostic: 'docker 500')
    check = report.check(:danger_claude)[:checks][:danger_claude]

    assert_equal :down, check[:status]
    assert_equal 2, check[:meta][:consecutive]
  end

  test 'a broken probe after a healthy one is not a streak' do
    usage_event(available: true, status: 'available', age_seconds: 30)
    usage_event(available: false, status: 'broken', diagnostic: 'docker 500')
    check = report.check(:danger_claude)[:checks][:danger_claude]

    assert_equal :warn, check[:status], 'a healthy probe in between must break the run'
  end

  test 'danger_claude ok when the verdict is stale' do
    usage_event(available: false, status: 'auth_refused', age_seconds: 5_000)

    assert_equal :ok, report.check(:danger_claude)[:status]
  end

  # A row written before Autodev #108 (no `status` key) must not crash the
  # card — see Autodev::UsageGate#state.
  test 'danger_claude does not crash on a pre-upgrade row with no status key' do
    ActivityEvent.create!(issue_id: nil, kind: 'usage', level: 'warn',
                          payload_json: JSON.generate(available: false))

    assert_equal :ok, report.check(:danger_claude)[:status]
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
    assert_equal %i[poller workers queue claude_usage danger_claude issues_error
                    mr_review review_skill mr_review_token stuck_issues database
                    migrations gitlab_requests],
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

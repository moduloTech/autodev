# frozen_string_literal: true

require_relative '../../rails_helper'

# Sliding retention on `activity_events` (Autodev #57).
#
# Autodev #53 collapsed the per-poll row that made 53 % of the table, and
# shipped a one-shot rake purge for the arrears. Neither bounds growth: nothing
# ever deleted a row, and Autodev #50's `heartbeat` kind opened a fresh (slower)
# leak in the same family. This janitor is the sliding window.
#
# The load-bearing constraint is Autodev #50's invariant. `Issue.without_activity_since`
# deliberately counts heartbeats: a live-but-quiet worker stays out of the
# dormant audit's population only because its heartbeat is younger than
# `HealthReport#stuck_active_after`. A purge that reaches inside that window
# would delete the very row that proves the worker alive, and the audit — which
# mutates by `update_all`, outside the per-issue concurrency lock — would
# reposition a row somebody is still working on. Hence the retention window is
# *derived* from that one, never configured independently of it.
class ActivityEventJanitorTest < ActiveSupport::TestCase # rubocop:disable Metrics/ClassLength
  CONFIG = { 'poll_interval' => 300 }.freeze
  STUCK_WINDOW = Autodev::HealthReport::STUCK_ACTIVE_AFTER # 7200

  setup do
    @now = Time.utc(2026, 8, 12, 12, 0, 0)
  end

  def janitor(config: CONFIG)
    Autodev::ActivityEventJanitor.new(config: config, now: @now)
  end

  def issue(**attrs)
    Issue.create!({ project_path: 'group/project', issue_iid: rand(1_000_000),
                    status: 'implementing', created_at: @now - 30.days }.merge(attrs))
  end

  def event(kind:, age:, issue_id: nil)
    ActivityEvent.create!(issue_id: issue_id, kind: kind, level: 'info',
                          payload_json: '{}', created_at: @now - age)
  end

  def project(**attrs)
    Project.create!({ gitlab_path: 'group/proj', slug: 'group__proj' }.merge(attrs))
  end

  # --- what gets deleted ---------------------------------------------------

  test 'deletes a machinery row older than the retention window' do
    stale = event(kind: 'poller', age: 40.hours)

    assert_equal 1, janitor.run[:deleted]
    refute ActivityEvent.exists?(stale.id)
  end

  test 'keeps a machinery row inside the retention window' do
    fresh = event(kind: 'poller', age: 6.hours)

    assert_equal 0, janitor.run[:deleted]
    assert ActivityEvent.exists?(fresh.id)
  end

  # Business rows are the audit trail the issue timeline renders. The #53
  # collapse bounds them per issue; nothing here may touch them, whatever
  # their age.
  test 'never deletes a business row, however old' do
    tracked = issue
    kept = %w[transition danger_claude discussions_snapshot].map do |kind|
      event(kind: kind, age: 400.days, issue_id: tracked.id)
    end

    janitor.run

    assert_equal kept.map(&:id).sort, ActivityEvent.where(issue_id: tracked.id).pluck(:id).sort
  end

  # Constat 3 of the ticket: "masqué" had two competing definitions — the
  # `user_visible` scope and a hardcoded three-kind list in the sparkline. There
  # is now one list, and it is the same one the purge acts on: a kind nobody
  # asked to see is a kind we are free to drop.
  test 'the kinds it purges are exactly the ones user_visible hides' do
    tracked = issue
    ActivityEvent::KINDS.each { |kind| event(kind: kind, age: 400.days, issue_id: tracked.id) }

    janitor.run

    assert_equal (ActivityEvent::KINDS - ActivityEvent::MACHINERY_KINDS).sort,
                 ActivityEvent.distinct.pluck(:kind).sort
  end

  test 'is idempotent' do
    event(kind: 'heartbeat', age: 40.hours)
    janitor.run

    assert_equal 0, janitor.run[:deleted]
  end

  # --- how the window is sized --------------------------------------------

  test 'defaults to twelve times the stuck window' do
    assert_equal 12 * STUCK_WINDOW, janitor.retention_seconds
    assert_equal 86_400, janitor.retention_seconds, '24 h at default settings'
  end

  test 'widens with the stuck window when a project raises a timeout' do
    project(dc_timeout: 5400) # 2 × 5400 = 10_800 > the 7200 floor

    assert_equal 12 * 10_800, janitor.retention_seconds
  end

  test 'a configured retention longer than the derived floor wins' do
    config = CONFIG.merge('monitoring' => { 'activity_event_retention_seconds' => 30.days.to_i })

    assert_equal 30.days.to_i, janitor(config: config).retention_seconds
  end

  # The trap the ticket names: a retention configured under the safety window
  # makes a live worker look dormant. The derived value is a floor, so the
  # narrower setting is ignored rather than obeyed.
  test 'a configured retention shorter than the derived floor is ignored' do
    config = CONFIG.merge('monitoring' => { 'activity_event_retention_seconds' => 600 })

    assert_equal 12 * STUCK_WINDOW, janitor(config: config).retention_seconds
  end

  # Held at the worst case a project can actually configure. That used to be
  # written as an arbitrary `86_400`; since Autodev #58 the timeouts are bounded,
  # so the extreme is the declared ceiling — and reading it off the registry means
  # this test follows the bound instead of restating a number that can drift.
  test 'the retention window always clears the stuck window' do
    project(dc_timeout: NumericSettings::TIMEOUT_MAX)
    config = CONFIG.merge('monitoring' => { 'activity_event_retention_seconds' => 1 })
    subject = janitor(config: config)

    assert_operator subject.retention_seconds, :>,
                    Autodev::HealthReport.new(config: config, now: @now).stuck_active_after
  end

  # --- Autodev #50's invariant --------------------------------------------

  # The whole reason the window is derived. The issue's only activity is
  # heartbeats: ancient ones the purge removes, plus one inside the stuck
  # window. It must stay out of the dormant population after the purge — if the
  # purge reached that row, the audit would reposition a live worker's ticket.
  test 'a purge never turns a live-but-quiet worker into a dormant row' do
    tracked = issue
    3.times { |i| event(kind: 'heartbeat', age: (40 + i).hours, issue_id: tracked.id) }
    live = event(kind: 'heartbeat', age: 10.minutes, issue_id: tracked.id)

    janitor.run

    assert ActivityEvent.exists?(live.id), 'the heartbeat inside the stuck window must survive'
    assert_empty Issue.where(status: 'implementing')
                      .without_activity_since(@now - STUCK_WINDOW).pluck(:id)
  end

  # The mirror image: the purge must not *hide* a genuinely dead worker either.
  # A row whose last heartbeat predates the stuck window was already dormant
  # before the purge and stays dormant after it.
  test 'a purge leaves a genuinely dormant row dormant' do
    tracked = issue
    event(kind: 'heartbeat', age: 40.hours, issue_id: tracked.id)

    janitor.run

    assert_equal [tracked.id], Issue.where(status: 'implementing')
                                    .without_activity_since(@now - STUCK_WINDOW).pluck(:id)
  end

  # --- the machinery readers keep reading ---------------------------------

  # `HealthReport#check_poller` reads the newest `poller` row. The retention
  # window is 12 × the stuck window, itself far past `poll_stale_after`, so a
  # ticking poller always keeps its evidence.
  test 'a ticking poller still reads as healthy after a purge' do
    event(kind: 'poller', age: 400.days)
    event(kind: 'poller', age: 1.minute)

    janitor.run
    report = Autodev::HealthReport.new(config: CONFIG, now: @now, poller_expected: true)

    assert_equal :ok, report.check(:poller)[:checks][:poller][:status]
  end

  # `UsageGate.state` reads the newest `usage` row, trusted for two poll
  # intervals — three orders of magnitude inside the retention window.
  test 'the Claude-quota verdict is still readable after a purge' do
    ActivityEvent.create!(issue_id: nil, kind: 'usage', level: 'warn',
                          payload_json: JSON.generate(available: false), created_at: @now - 1.minute)
    event(kind: 'usage', age: 400.days)

    janitor.run

    refute Autodev::UsageGate.available?(config: CONFIG, now: @now)
  end
end

# frozen_string_literal: true

require_relative '../rails_helper'

# The `mr_review` health check (Autodev #60, item 1) — the missing alert behind
# Autodev #49.
#
# `review_failure_count` is per ticket, and `review_failures_exhausted` raises a
# per-ticket `needs_attention` flag. When mr-review is broken for *everybody* —
# expired token, a crashing binary, a bad release — that produces N independent
# per-ticket flags and nothing that says the tool is dead. Nobody correlates
# three isolated tickets: in production the real outage ran for weeks and three
# MRs shipped unreviewed.
#
# So the check counts across all projects, over a sliding window, and warns past
# a threshold. Both are calibrated on the 12/08/2026 production copy rather than
# guessed — see the constants' comment in HealthReport for the numbers.
class HealthReportMrReviewTest < ActiveSupport::TestCase
  CONFIG = { 'poll_interval' => 300 }.freeze

  def check(config: CONFIG)
    Autodev::HealthReport.new(config: config).check(:mr_review)[:checks][:mr_review]
  end

  # One row per iid, in its own project — the check is cross-project by design.
  def issue(iid)
    Issue.find_or_create_by!(project_path: "group/p#{iid}", issue_iid: iid) do |row|
      row.status = 'checking_pipeline'
    end
  end

  # The two activity keys mr-review failures are recorded under:
  # `review_failed` per attempt, `review_failures_exhausted` on the last one.
  def failure_event(iid, key: 'review_failed', age_seconds: 0)
    ActivityEvent.create!(
      issue_id: issue(iid).id, kind: 'danger_claude', level: 'info',
      payload_json: JSON.generate(key: key, vars: { count: 1 }, message: 'mr-review failed'),
      created_at: Time.now.utc - age_seconds
    )
  end

  test 'ok when nothing failed' do
    assert_equal :ok, check[:status]
  end

  # One broken ticket burning its five attempts is the *normal* shape of this
  # signal: every isolated incident in four months of production data is exactly
  # one ticket. It must not page anybody.
  test 'ok for a single ticket failing repeatedly' do
    5.times { failure_event(4242) }

    assert_equal :ok, check[:status]
  end

  test 'warn once the threshold of distinct tickets is reached' do
    [1, 2, 3].each { |iid| failure_event(iid) }

    assert_equal :warn, check[:status]
  end

  # The count is of *tickets*, not events. Autodev #61's replay put 26 identical
  # give-up comments on one ticket, so an event count would have been inflated by
  # a bug that had nothing to do with mr-review's health.
  test 'counts distinct issues, not events' do
    2.times { |i| 20.times { failure_event(i + 1) } }

    result = check

    assert_equal :ok, result[:status]
    assert_equal 2, result[:meta][:issues]
  end

  test 'the exhausted key counts too' do
    [1, 2, 3].each { |iid| failure_event(iid, key: 'review_failures_exhausted') }

    assert_equal :warn, check[:status]
  end

  test 'failures older than the window are ignored' do
    [1, 2, 3].each { |iid| failure_event(iid, age_seconds: 7.hours.to_i) }

    assert_equal :ok, check[:status]
  end

  test 'the window and the threshold are reported in meta' do
    meta = check[:meta]

    assert_equal [21_600, 3], [meta[:window_seconds], meta[:threshold]]
  end

  test 'the window is configurable' do
    [1, 2, 3].each { |iid| failure_event(iid, age_seconds: 7.hours.to_i) }
    config = CONFIG.merge('monitoring' => { 'review_failure_window_seconds' => 28_800 })

    assert_equal :warn, check(config: config)[:status]
  end

  test 'the threshold is configurable' do
    [1, 2].each { |iid| failure_event(iid) }
    config = CONFIG.merge('monitoring' => { 'review_failure_threshold' => 2 })

    assert_equal :warn, check(config: config)[:status]
  end

  # A ticket-level activity key that merely contains the pattern must not be
  # read as a review failure — `_` is a LIKE wildcard, so the SQL escapes it.
  test 'an unrelated activity key is not counted' do
    [1, 2, 3].each { |iid| failure_event(iid, key: 'reviewing') }

    assert_equal :ok, check[:status]
  end

  # warn, not down: mr-review being broken does not stop delivery, so /healthz
  # must keep answering 200 for the uptime probe while the JSON carries the warn.
  test 'the check is part of the full report and only ever warns' do
    [1, 2, 3].each { |iid| failure_event(iid) }
    report = Autodev::HealthReport.new(config: CONFIG).call

    assert_includes report[:checks].keys, :mr_review
    assert_equal :warn, report[:checks][:mr_review][:status]
  end
end

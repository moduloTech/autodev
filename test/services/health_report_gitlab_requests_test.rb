# frozen_string_literal: true

require_relative '../rails_helper'

# The `gitlab_requests` health check (Autodev #96) — passive like every other
# HealthReport check: it never calls GitLab, it reads what
# GitlabRequestCounter already recorded on the last however-many real calls.
# It exists to turn the instruction's point 1 (a derived ~30-45
# requests/cycle estimate) and point 3 (an indecidable-by-hand hourly
# failure curve) into numbers read off the database instead of the code.
class HealthReportGitlabRequestsTest < ActiveSupport::TestCase
  def check
    Autodev::HealthReport.new.check(:gitlab_requests)[:checks][:gitlab_requests]
  end

  test 'ok with no data on file' do
    result = check

    assert_equal :ok, result[:status]
    assert_equal 0, result[:meta][:total_last_hour]
    assert_in_delta(0.0, result[:meta][:failure_rate_pct])
  end

  test 'reports reads and writes in the last hour separately' do
    now = Time.now.utc
    GitlabRequestStat.record!(kind: :read, endpoint: 'issue', at: now - 60)
    GitlabRequestStat.record!(kind: :write, endpoint: 'create_issue_note', at: now - 30)

    meta = check[:meta]

    assert_equal 1, meta[:reads_last_hour]
    assert_equal 1, meta[:writes_last_hour]
    assert_equal 2, meta[:total_last_hour]
  end

  test 'requests older than an hour do not count towards the hourly totals' do
    GitlabRequestStat.record!(kind: :read, endpoint: 'issue', at: Time.now.utc - 7_200)

    assert_equal 0, check[:meta][:total_last_hour]
  end

  test 'reports the failure rate over the last 24h' do
    now = Time.now.utc
    3.times { |i| GitlabRequestStat.record!(kind: :read, endpoint: 'issue', at: now - (i * 60)) }
    GitlabTransportFailure.record!(kind: :read, endpoint: 'issue', error: StandardError.new('x'), at: now - 60)

    meta = check[:meta]

    assert_equal 3, meta[:requests_last_24h]
    assert_equal 1, meta[:failures_last_24h]
    assert_in_delta 33.33, meta[:failure_rate_pct], 0.01
  end

  test 'failures older than 24h do not count' do
    GitlabRequestStat.record!(kind: :read, endpoint: 'issue', at: Time.now.utc - 60)
    GitlabTransportFailure.record!(kind: :read, endpoint: 'issue', error: StandardError.new('x'),
                                   at: Time.now.utc - 90_000)

    assert_equal 0, check[:meta][:failures_last_24h]
  end

  test 'never warns — no baseline exists yet to warn against' do
    50.times { GitlabTransportFailure.record!(kind: :read, endpoint: 'issue', error: StandardError.new('x')) }

    assert_equal :ok, check[:status]
  end

  test 'the check is part of the full report' do
    report = Autodev::HealthReport.new.call

    assert_includes report[:checks].keys, :gitlab_requests
  end
end

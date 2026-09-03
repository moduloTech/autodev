# frozen_string_literal: true

require_relative 'test_helper'

# Autodev #96: GitlabRequestStat is an hourly counter of GitLab API calls,
# one row per (hour_bucket, kind, endpoint), bumped by an upsert rather than
# inserted per call. See the design spec for why a counter and not a log.
class GitlabRequestStatTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
  end

  def test_table_created_by_migration
    assert_includes ActiveRecord::Base.connection.tables, 'gitlab_request_stats'
  end

  def test_record_creates_a_row_on_first_call
    GitlabRequestStat.record!(kind: :read, endpoint: 'merge_request')

    row = GitlabRequestStat.sole

    assert_equal 'read', row.kind
    assert_equal 'merge_request', row.endpoint
    assert_equal 1, row.count
  end

  def test_record_bumps_the_same_row_within_the_same_hour
    at = Time.utc(2026, 9, 3, 10, 15)
    GitlabRequestStat.record!(kind: :read, endpoint: 'merge_request', at: at)
    GitlabRequestStat.record!(kind: :read, endpoint: 'merge_request', at: at + 60)

    assert_equal 2, GitlabRequestStat.sole.count
  end

  def test_record_keeps_read_and_write_separate
    at = Time.utc(2026, 9, 3, 10, 15)
    GitlabRequestStat.record!(kind: :read, endpoint: 'merge_request', at: at)
    GitlabRequestStat.record!(kind: :write, endpoint: 'merge_request', at: at)

    assert_equal 2, GitlabRequestStat.count
    assert_equal 1, GitlabRequestStat.find_by(kind: 'read').count
    assert_equal 1, GitlabRequestStat.find_by(kind: 'write').count
  end

  def test_record_starts_a_new_bucket_the_next_hour
    GitlabRequestStat.record!(kind: :read, endpoint: 'issue', at: Time.utc(2026, 9, 3, 10, 45))
    GitlabRequestStat.record!(kind: :read, endpoint: 'issue', at: Time.utc(2026, 9, 3, 11, 5))

    assert_equal 2, GitlabRequestStat.count
    assert_equal [1, 1], GitlabRequestStat.order(:hour_bucket).pluck(:count)
  end

  def test_record_never_raises_when_the_write_fails
    GitlabRequestStat.stub(:upsert_all, ->(*) { raise ActiveRecord::StatementInvalid, 'boom' }) do
      GitlabRequestStat.record!(kind: :read, endpoint: 'issue')
    end

    assert_equal 0, GitlabRequestStat.count
  end

  def test_by_kind_since_sums_counts_grouped_by_kind
    now = Time.utc(2026, 9, 3, 12, 0)
    GitlabRequestStat.record!(kind: :read, endpoint: 'issue', at: now - 1_800)
    GitlabRequestStat.record!(kind: :read, endpoint: 'merge_request', at: now - 900)
    GitlabRequestStat.record!(kind: :write, endpoint: 'create_issue_note', at: now - 300)
    GitlabRequestStat.record!(kind: :read, endpoint: 'issue', at: now - 90_000) # outside the window

    by_kind = GitlabRequestStat.by_kind_since(now - 3_600)

    assert_equal 2, by_kind['read']
    assert_equal 1, by_kind['write']
  end

  def test_total_since_sums_across_kinds
    now = Time.utc(2026, 9, 3, 12, 0)
    GitlabRequestStat.record!(kind: :read, endpoint: 'issue', at: now - 100)
    GitlabRequestStat.record!(kind: :write, endpoint: 'create_issue_note', at: now - 200)

    assert_equal 2, GitlabRequestStat.total_since(now - 3_600)
  end

  def test_total_since_is_zero_with_no_rows
    assert_equal 0, GitlabRequestStat.total_since(Time.now.utc - 3_600)
  end
end

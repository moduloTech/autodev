# frozen_string_literal: true

require_relative 'test_helper'

# Autodev #96: GitlabTransportFailure is a row per transport failure —
# GitlabHelpers::TRANSPORT_ERRORS's own family — with millisecond precision,
# so it can answer the instruction's point 3 (an hourly failure curve) that
# four hand-timed samples could not.
class GitlabTransportFailureTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
  end

  def test_table_created_by_migration
    assert_includes ActiveRecord::Base.connection.tables, 'gitlab_transport_failures'
  end

  def test_record_creates_a_row
    error = Net::OpenTimeout.new('timed out')

    GitlabTransportFailure.record!(kind: :read, endpoint: 'merge_request', error: error,
                                   caller_location: 'lib/autodev/pipeline_monitor.rb:42')

    row = GitlabTransportFailure.sole

    assert_equal ['read', 'merge_request', 'Net::OpenTimeout', 'timed out', 'lib/autodev/pipeline_monitor.rb:42'],
                 [row.kind, row.endpoint, row.error_class, row.error_message, row.caller_location]
  end

  def test_record_captures_the_occurred_at_with_millisecond_precision
    at = Time.utc(2026, 9, 3, 10, 15, 30.123456)

    GitlabTransportFailure.record!(kind: :read, endpoint: 'issue', error: StandardError.new('x'), at: at)

    row = GitlabTransportFailure.sole

    assert_in_delta at.to_f, row.occurred_at.to_f, 0.001
  end

  def test_record_never_raises_when_the_write_fails
    GitlabTransportFailure.stub(:create!, ->(*) { raise ActiveRecord::StatementInvalid, 'boom' }) do
      GitlabTransportFailure.record!(kind: :read, endpoint: 'issue', error: StandardError.new('x'))
    end

    assert_equal 0, GitlabTransportFailure.count
  end

  def test_count_since_counts_only_failures_inside_the_window
    now = Time.utc(2026, 9, 3, 12, 0)
    GitlabTransportFailure.record!(kind: :read, endpoint: 'issue', error: StandardError.new('a'), at: now - 3_600)
    GitlabTransportFailure.record!(kind: :read, endpoint: 'issue', error: StandardError.new('b'), at: now - 90_000)

    assert_equal 1, GitlabTransportFailure.count_since(now - 86_400)
  end

  def test_recent_orders_newest_first_and_respects_limit
    now = Time.utc(2026, 9, 3, 12, 0)
    GitlabTransportFailure.record!(kind: :read, endpoint: 'older', error: StandardError.new('a'), at: now - 200)
    GitlabTransportFailure.record!(kind: :read, endpoint: 'newer', error: StandardError.new('b'), at: now - 10)

    assert_equal %w[newer older], GitlabTransportFailure.recent(limit: 5).map(&:endpoint)
  end
end

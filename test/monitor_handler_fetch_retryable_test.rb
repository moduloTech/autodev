# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/poller'

# Targets MonitorHandler#fetch_retryable in isolation.
# Reproduces the bug fixed in this commit: pending issues with `next_retry_at`
# in the past (left behind when retry_processing! flipped error → pending
# but the labels_todo poll no longer surfaced the issue) were never picked
# back up.
class MonitorHandlerFetchRetryableTest < Minitest::Test
  include DatabaseTestHelper

  # Minimal host for the module so we can call its private methods.
  class Host
    include Poller::MonitorHandler

    def initialize(config)
      @config = config
    end

    public :fetch_retryable
  end

  def setup
    setup_database
    @host = Host.new('max_retries' => 6)
    @cfg = { 'path' => 'group/project', 'max_retries' => 6 }
  end

  def past
    (Time.now - 3600).strftime('%Y-%m-%d %H:%M:%S')
  end

  def future
    (Time.now + 3600).strftime('%Y-%m-%d %H:%M:%S')
  end

  def test_fetches_errored_issue_with_past_next_retry_at
    create_issue(status: 'error', retry_count: 1, next_retry_at: past)

    assert_equal 1, @host.fetch_retryable(@cfg).size
  end

  def test_fetches_stuck_pending_issue_with_past_next_retry_at
    create_issue(status: 'pending', retry_count: 1, next_retry_at: past)

    assert_equal 1, @host.fetch_retryable(@cfg).size
  end

  def test_skips_fresh_pending_issue_without_next_retry_at
    create_issue(status: 'pending', retry_count: 0, next_retry_at: nil)

    assert_empty @host.fetch_retryable(@cfg)
  end

  def test_skips_pending_with_future_next_retry_at
    create_issue(status: 'pending', retry_count: 1, next_retry_at: future)

    assert_empty @host.fetch_retryable(@cfg)
  end

  def test_respects_max_retries_for_pending
    create_issue(status: 'pending', retry_count: 6, next_retry_at: past)

    assert_empty @host.fetch_retryable(@cfg)
  end

  def test_scopes_by_project_path
    create_issue(project_path: 'other/project', status: 'pending', retry_count: 1, next_retry_at: past)

    assert_empty @host.fetch_retryable(@cfg)
  end
end

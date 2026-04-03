# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/worker_pool'

class WorkerPoolTest < Minitest::Test
  def setup
    @logger = FakePastel.new
    # FakePastel doesn't have #error, add a no-op
    def @logger.error(msg) = nil
  end

  def test_enqueue_and_execute
    pool = WorkerPool.new(size: 1, logger: @logger)
    pool.start
    executed = false
    pool.enqueue? { executed = true }
    sleep 0.2
    pool.shutdown

    assert executed
  end

  def test_enqueue_deduplicates_by_iid
    pool = WorkerPool.new(size: 1, logger: @logger)
    count = 0
    pool.start

    assert pool.enqueue?(issue_iid: 42) { count += 1 }
    refute pool.enqueue?(issue_iid: 42) { count += 1 }

    sleep 0.2
    pool.shutdown

    assert_equal 1, count
  end

  def test_assignments_tracks_active_workers
    pool = WorkerPool.new(size: 1, logger: @logger)
    pool.start
    started = Queue.new
    finish = Queue.new
    pool.enqueue?(issue_iid: 99) do
      started.push(true)
      finish.pop
    end
    started.pop # wait for job to start

    refute_empty pool.assignments

    finish.push(true)
    sleep 0.2
    pool.shutdown
  end
end

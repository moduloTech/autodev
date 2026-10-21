# frozen_string_literal: true

require_relative '../rails_helper'
require_relative '../queue_database_on_file'

# The `workers` card on a real Solid Queue `processes` table (Autodev #139).
# Since the poll has a worker process of its own, "a worker is alive" no
# longer means the IssueProcessJobs are served: the card asks, per queue the
# product depends on, whether an alive worker serves it.
class HealthReportWorkersTest < ActiveSupport::TestCase
  include QueueDatabaseOnFile

  setup { use_queue_database_on_file }
  teardown { restore_queue_database }

  test 'ok when the default and the poll workers are both alive' do
    worker('default,solid_queue_recurring')
    worker('poll')

    assert_equal :ok, check[:status]
  end

  test 'down when only the poll worker is alive' do
    worker('poll')

    result = check

    assert_equal :down, result[:status]
    assert_equal ['default'], result[:meta][:unserved_queues]
  end

  test 'down when only the default worker is alive' do
    worker('default,solid_queue_recurring')

    assert_equal ['poll'], check[:meta][:unserved_queues]
  end

  test 'a worker past the heartbeat threshold does not count' do
    worker('default,solid_queue_recurring')
    worker('poll', heartbeat: Time.current - SolidQueue.process_alive_threshold - 60)

    assert_equal ['poll'], check[:meta][:unserved_queues]
  end

  test 'a "*" worker serves every queue, as before the split' do
    worker('*')

    assert_equal :ok, check[:status]
  end

  private

  def check
    Autodev::HealthReport.new(config: {}).check(:workers)[:checks][:workers]
  end

  def worker(queues, heartbeat: Time.current)
    SolidQueue::Process.create!(
      kind: 'Worker', name: "worker-#{SecureRandom.hex(4)}", pid: rand(100_000), hostname: 'test',
      last_heartbeat_at: heartbeat, metadata: { queues: queues, thread_pool_size: 1 }
    )
  end
end

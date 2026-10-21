# frozen_string_literal: true

require_relative '../rails_helper'
require_relative '../queue_database_on_file'

# A poll a worker claims steps aside when a newer one already waits on its
# queue (Autodev #139): with one poll thread, cycles longer than the interval
# would otherwise pile the scheduler's ticks up behind each other for as long
# as they stay long, and every one of them would re-read the same state.
class AutodevPollJobSupersededTest < ActiveSupport::TestCase
  include QueueDatabaseOnFile

  setup { use_queue_database_on_file }
  teardown { restore_queue_database }

  test 'a claimed poll with a newer poll waiting runs no cycle' do
    enqueue_poll

    assert_empty cycles(claimed_poll)
  end

  test 'a claimed poll with nothing waiting runs its cycle' do
    assert_equal [:cycle], cycles(claimed_poll)
  end

  test 'perform_now always runs, a poll waiting or not' do
    enqueue_poll

    assert_equal [:cycle], cycles(AutodevPollJob.new)
  end

  test 'an IssueProcessJob waiting does not supersede the poll' do
    SolidQueue::Job.enqueue(IssueProcessJob.new('group/foo', 1, 'check_pipeline'))

    assert_equal [:cycle], cycles(claimed_poll)
  end

  private

  def enqueue_poll
    SolidQueue::Job.enqueue(AutodevPollJob.new)
  end

  # What a worker hands `perform`: a job carrying the id Solid Queue gave it.
  def claimed_poll
    AutodevPollJob.new.tap { |job| job.provider_job_id = 1 }
  end

  def cycles(job)
    ran = []
    Config.stub(:load, {}) do
      job.stub(:probe_usage, true) do
        job.stub(:run_cycle, ->(*, **) { ran << :cycle and 0 }) { job.perform }
      end
    end
    ran
  end
end

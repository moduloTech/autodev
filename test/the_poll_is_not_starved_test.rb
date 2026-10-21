# frozen_string_literal: true

require_relative 'rails_helper'
require_relative 'queue_database_on_file'

# Autodev #139: the poll waited behind the work it had itself enqueued. On
# 15/10/2026 the three threads of the one `"*"` worker were held by
# `IssueProcessJob :check_pipeline` runs of 24 to 27 minutes, every poll the
# scheduler enqueued meanwhile sat behind the older `IssueProcessJob`s still in
# the queue, and `/healthz` went `down` on `poller` three times in the day.
#
# This drives the real thing rather than asserting a configuration: real Solid
# Queue workers, built from `config/queue.yml` by Solid Queue's own
# `Configuration`, claim jobs from a real queue database; the poll is enqueued
# by the `autodev_poll` recurring task of `config/recurring.yml`, which is how
# the scheduler enqueues it in production (its `queue:` overrides the class's
# `queue_as`). Only the job bodies are stand-ins, and their queues are read off
# the real classes.
class ThePollIsNotStarvedTest < ActiveSupport::TestCase
  include QueueDatabaseOnFile

  LONG_JOBS = 5
  WAIT_SECONDS = 5

  # A long `IssueProcessJob`: holds its thread until the test releases it.
  class LongIssueWork < ActiveJob::Base
    self.queue_adapter = :solid_queue
    queue_as IssueProcessJob.queue_name

    def perform(index)
      ThePollIsNotStarvedTest.ran << [:long, index]
      ThePollIsNotStarvedTest.latch.pop
    end
  end

  # The poll's body: says it ran.
  class PollTick < ActiveJob::Base
    self.queue_adapter = :solid_queue
    queue_as AutodevPollJob.queue_name

    def perform
      ThePollIsNotStarvedTest.ran << [:poll]
    end
  end

  class << self
    attr_accessor :ran, :latch
  end

  setup do
    self.class.ran = Queue.new
    self.class.latch = Queue.new
    use_queue_database_on_file
    @workers = []
  end

  teardown do
    LONG_JOBS.times { self.class.latch << :release }
    @workers.each(&:stop)
    restore_queue_database
  end

  test 'a poll enqueued while every IssueProcessJob thread is busy still runs' do
    start_workers
    LONG_JOBS.times { |index| LongIssueWork.perform_later(index) }
    busy = collect(until_count: issue_threads)

    assert_equal [issue_threads, LONG_JOBS - issue_threads], [busy.size, waiting_issue_jobs],
                 '[long jobs holding every thread, older IssueProcessJobs still waiting], as on 15/10'

    recurring_poll.enqueue(at: Time.current)

    assert_includes collect(until_count: 1), [:poll], 'the poll waited behind the IssueProcessJobs it enqueued'
    assert_equal issue_threads, running_long_jobs, 'the long jobs must still hold their threads when the poll runs'
  end

  private

  def configuration
    @configuration ||= SolidQueue::Configuration.new(
      config_file: Rails.root.join('config/queue.yml'), only_work: true
    )
  end

  def start_workers
    @workers = configuration.configured_processes.map do |process|
      process.instantiate.tap(&:start)
    end
  end

  # The threads that can run an IssueProcessJob: every worker serving its queue.
  def issue_threads
    queue = IssueProcessJob.queue_name.to_s
    configuration.configured_processes.sum do |process|
      queues = Array(process.attributes[:queues]).map(&:to_s)
      queues.include?('*') || queues.include?(queue) ? process.attributes[:threads].to_i : 0
    end
  end

  # The production `autodev_poll` entry, with its body swapped for PollTick.
  def recurring_poll
    entry = YAML.load(ERB.new(Rails.root.join('config/recurring.yml').read).result, aliases: true)
                .fetch('production').fetch('autodev_poll')
    SolidQueue::RecurringTask.from_configuration(
      'autodev_poll', **entry.symbolize_keys, class: PollTick.name
    )
  end

  def waiting_issue_jobs
    SolidQueue::ReadyExecution.where(queue_name: IssueProcessJob.queue_name.to_s).count
  end

  def running_long_jobs
    SolidQueue::ClaimedExecution.joins(:job).where(solid_queue_jobs: { class_name: LongIssueWork.name }).count
  end

  def collect(until_count:)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + WAIT_SECONDS
    seen = []
    while seen.size < until_count && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
      item = self.class.ran.pop(timeout: 0.1)
      seen << item if item
    end
    seen
  end
end

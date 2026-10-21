# frozen_string_literal: true

require_relative 'rails_helper'

# Autodev #139 gave the poll a worker of its own, which meant replacing the
# `"*"` worker with explicit queue lists. A queue nobody lists is a queue whose
# jobs wait for ever, in silence: `clear_solid_queue_finished_jobs` is a
# `command:` task, and Solid Queue runs those as its own `RecurringJob`, on
# `solid_queue_recurring`, a queue no file of this repository names.
#
# So every queue a job can land on is derived here, not listed: the
# `queue_as` of every class in `app/jobs`, the framework jobs this app loads,
# and every recurring task of every environment, resolved the way
# `SolidQueue::RecurringTask` resolves it (its `queue:` else its class's
# queue, `RecurringJob`'s for a command). Each must be served by a worker of
# every environment of `config/queue.yml`.
class QueuesAreServedTest < ActiveSupport::TestCase
  ENVIRONMENTS = %w[development test production].freeze

  FRAMEWORK_JOBS = %w[
    ActiveStorage::AnalyzeJob ActiveStorage::PurgeJob ActiveStorage::MirrorJob
    ActiveStorage::TransformJob Turbo::Streams::BroadcastJob
    Turbo::Streams::BroadcastStreamJob Turbo::Streams::ActionBroadcastJob
  ].freeze

  test 'every queue a job can land on is served in every environment' do
    ENVIRONMENTS.each do |env|
      queue_landings.each do |source, queue|
        assert served?(workers(env), queue), "#{env}: #{source} lands on #{queue.inspect}, which no worker serves"
      end
    end
  end

  test 'the derivation reaches the jobs that motivated it' do
    sources = queue_landings.to_h

    assert_equal 'solid_queue_recurring', sources.fetch('recurring production:clear_solid_queue_finished_jobs')
    assert_includes sources.keys, 'IssueProcessJob'
    assert_includes sources.keys, 'AutodevPollJob'
  end

  test 'the scheduler enqueues the poll on the poll class queue' do
    entry = recurring('production').fetch(:autodev_poll)

    assert_equal 'poll', AutodevPollJob.queue_name
    assert_equal AutodevPollJob.queue_name, (entry[:queue] || AutodevPollJob.queue_name).to_s,
                 'a recurring `queue:` overrides queue_as: the poll would land elsewhere'
  end

  test 'the poll has one worker, and it serves nothing else' do
    poll = AutodevPollJob.queue_name

    ENVIRONMENTS.each do |env|
      serving = workers(env).select { |worker| served?([worker], poll) }

      assert_equal 1, serving.size, "#{env}: #{serving.size} workers serve #{poll}"
      assert_equal [poll], Array(serving.first[:queues]).map(&:to_s), "#{env}: the poll worker serves other queues"
    end
  end

  test 'the poll worker is one process with one thread: polls are serialised' do
    ENVIRONMENTS.each do |env|
      worker = workers(env).find { |w| served?([w], AutodevPollJob.queue_name) }

      assert_equal [1, 1], [worker[:threads], worker.fetch(:processes, 1)], "#{env}: [threads, processes]"
    end
  end

  test 'no worker that runs IssueProcessJob can claim the poll' do
    issue = IssueProcessJob.queue_name
    poll = AutodevPollJob.queue_name

    ENVIRONMENTS.each do |env|
      workers(env).select { |worker| served?([worker], issue) }.each do |worker|
        refute served?([worker], poll), "#{env}: #{worker[:queues].inspect} serves both #{issue} and #{poll}"
      end
    end
  end

  test 'the IssueProcessJob worker still takes its thread count from AUTODEV_MAX_WORKERS' do
    ENVIRONMENTS.each do |env|
      worker = workers(env, max_workers: '7').find { |w| served?([w], IssueProcessJob.queue_name) }

      assert_equal 7, worker[:threads], "#{env}: threads no longer follow AUTODEV_MAX_WORKERS"
    end
  end

  private

  def queue_landings
    jobs = (app_jobs + FRAMEWORK_JOBS.filter_map(&:safe_constantize)).reject { |job| job == ApplicationJob }
    jobs.map { |job| [job.name, job.new.queue_name.to_s] } + recurring_landings
  end

  def app_jobs
    Rails.root.glob('app/jobs/*_job.rb').map { |file| file.basename('.rb').to_s.camelize.constantize }
  end

  def recurring_landings
    ENVIRONMENTS.flat_map do |env|
      recurring(env).map do |key, options|
        job = options[:class] ? options[:class].constantize : SolidQueue::RecurringJob
        ["recurring #{env}:#{key}", (options[:queue] || job.new.queue_name).to_s]
      end
    end
  end

  def recurring(env)
    render('config/recurring.yml').fetch(env.to_sym, {}) || {}
  end

  def workers(env, max_workers: nil)
    render('config/queue.yml', max_workers: max_workers).fetch(env.to_sym).fetch(:workers)
  end

  def render(path, max_workers: nil)
    previous = ENV.fetch('AUTODEV_MAX_WORKERS', nil)
    ENV['AUTODEV_MAX_WORKERS'] = max_workers if max_workers
    ActiveSupport::ConfigurationFile.parse(Rails.root.join(path)).deep_symbolize_keys
  ensure
    ENV['AUTODEV_MAX_WORKERS'] = previous
  end

  def served?(workers, queue)
    workers.any? { |worker| Autodev::QueuePatterns.serves?(Array(worker[:queues]), queue) }
  end
end

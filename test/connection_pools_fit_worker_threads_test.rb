# frozen_string_literal: true

require_relative 'rails_helper'

# Solid Queue refuses to start when the `queue` pool is smaller than its own
# estimate of the threads a worker process uses — the largest `threads:` of
# any worker, plus the worker's loop and its heartbeat — and `Supervisor.start`
# aborts. `max_workers` is declared `[1, 64]` in `NumericSettings::SPECS`, but
# with the pool fixed at 6 every value from 5 up made the `solid-queue` child
# abort at boot (measured while answering Autodev #139). The `IssueProcessJob`
# threads each check a `primary` connection out too, so that pool follows the
# same variable.
#
# The two YAML files are rendered here under each value of the declared range,
# the way each child process renders them from the `AUTODEV_MAX_WORKERS` the
# supervisor exports, and the estimate is Solid Queue's own method.
class ConnectionPoolsFitWorkerThreadsTest < ActiveSupport::TestCase
  ENVIRONMENTS = %i[development test production].freeze

  test 'every declared max_workers boots Solid Queue in every environment' do
    spec = NumericSettings::SPECS.fetch('max_workers')

    (spec.min..spec.max).each do |n|
      queue = render('config/queue.yml', n)
      database = render('config/database.yml', n)

      ENVIRONMENTS.each do |env|
        needed = SolidQueue::Configuration.new(config_file: queue.fetch(env))
                                          .send(:estimated_number_of_threads)

        assert_operator database.dig(env, :queue, :pool), :>=, needed, "N=#{n} #{env}: queue pool"
        assert_operator database.dig(env, :primary, :pool), :>=, n, "N=#{n} #{env}: primary pool"
      end
    end
  end

  test 'the pools do not shrink below the values production ran on' do
    database = render('config/database.yml', 3)

    ENVIRONMENTS.each do |env|
      assert_equal 6, database.dig(env, :queue, :pool)
      assert_equal 10, database.dig(env, :primary, :pool)
    end
  end

  private

  def render(path, max_workers)
    previous = ENV.fetch('AUTODEV_MAX_WORKERS', nil)
    ENV['AUTODEV_MAX_WORKERS'] = max_workers.to_s
    ActiveSupport::ConfigurationFile.parse(Rails.root.join(path)).deep_symbolize_keys
  ensure
    ENV['AUTODEV_MAX_WORKERS'] = previous
  end
end

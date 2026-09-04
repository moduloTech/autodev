# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'

# Autodev #110, measured in production on 04/09/2026 (powerpanne/core#16030):
# five enqueues in eighty seconds, all announcing "attempt 5", then jobs running
# 5/5, 6/5, 7/5, 8/5, 9/5. The dispatcher selected on two columns only the job
# wrote, so every cycle between the enqueue and the execution re-selected the
# same row.
class InfraRecheckReservationTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
    @path = 'group/project'
    @issue = ::Issue.create!(project_path: @path, issue_iid: 16_030, status: 'done',
                             mr_iid: 11_333, needs_attention: true,
                             attention_reason: 'stagnation_pipeline',
                             infra_recheck_count: 0, infra_recheck_at: nil)
  end

  def test_two_dispatch_cycles_without_a_job_running_enqueue_one_job
    enqueued = capture_enqueued do
      dispatcher.send(:dispatch_infra_recheck)
      dispatcher.send(:dispatch_infra_recheck)
    end

    assert_equal 1, enqueued.size,
                 'the second cycle must find the row reserved and enqueue nothing'
  end

  def test_the_reservation_moves_the_backoff_stamp_and_not_the_counter
    capture_enqueued { dispatcher.send(:dispatch_infra_recheck) }
    @issue.reload

    refute_nil @issue.infra_recheck_at, 'the dispatcher owns the clock now'
    assert_operator @issue.infra_recheck_at, :>, Time.current
    assert_equal 0, @issue.infra_recheck_count,
                 'the budget is spent by an attempt that looked at something, not by an enqueue'
  end

  def test_a_row_whose_backoff_has_not_elapsed_is_not_selected
    @issue.update!(infra_recheck_at: 1.hour.from_now)

    enqueued = capture_enqueued { dispatcher.send(:dispatch_infra_recheck) }

    assert_empty enqueued
  end

  def test_a_row_at_the_cap_is_not_selected
    @issue.update!(infra_recheck_count: 5)

    enqueued = capture_enqueued { dispatcher.send(:dispatch_infra_recheck) }

    assert_empty enqueued
  end

  private

  # `PollDispatcher.new` builds a real GitLab client from `config['gitlab_token']`
  # (`app/services/autodev/poll_dispatcher.rb:81`), which `dispatch_infra_recheck`
  # never touches. `.allocate.tap` sets only the ivars this pass reads, mirroring
  # `InfraRecheckDispatchTest#dispatcher`.
  def dispatcher
    Autodev::PollDispatcher.allocate.tap do |d|
      d.instance_variable_set(:@path, @path)
      d.instance_variable_set(:@project_config, { 'path' => @path })
      d.instance_variable_set(:@config, {})
      d.instance_variable_set(:@logger, Autodev::JobLogger.new(Logger.new(File::NULL)))
    end
  end

  # IssueProcessJob.perform_later is the seam; record the calls instead of
  # booting the queue.
  def capture_enqueued(&)
    calls = []
    IssueProcessJob.stub(:perform_later, ->(*args) { calls << args }, &)
    calls
  end
end

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

  # Restores the property `test_backoff_seconds_are_configurable` used to prove
  # for `record_recheck_attempt` before Autodev #110 moved the write here — the
  # spec says the interval is unchanged and only its writer moves, so the
  # assertion has to move with the writer. Without this, `reserve_infra_recheck?`
  # could stamp `1.second.from_now` (no reservation at all) or
  # `10.years.from_now` (the row parked for good) and every other test in this
  # file would still pass.
  def test_the_reservation_stamp_honours_the_configured_backoff
    capture_enqueued { dispatcher(config: { 'infra_recheck_backoff' => 60 }).send(:dispatch_infra_recheck) }
    @issue.reload

    assert_in_delta 60, @issue.infra_recheck_at - Time.current, 5
  end

  # Autodev #110, design's compare-and-set claim, unexercised until now (branch
  # review). Two cycles racing on one row both read the same candidate before
  # either writes — modelled here by calling the reservation twice against the
  # same row without an intervening `fetch_infra_recheck_candidates`, which is
  # exactly what let `::Issue.where(id: issue.id).update_all(...)` — the shape
  # the spec forbids — pass every other test in this file: the *second cycle*
  # is filtered out at the fetch, never at the reservation. Only a direct,
  # repeated call to `reserve_infra_recheck?` exercises the `next unless` guard
  # actually returning false.
  def test_a_losing_racer_does_not_reserve
    won = dispatcher.send(:reserve_infra_recheck?, @issue)
    lost = dispatcher.send(:reserve_infra_recheck?, @issue)

    assert won, 'the first racer must win'
    refute lost, 'the second racer must find the row no longer matching the predicate'
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
  def dispatcher(config: {})
    Autodev::PollDispatcher.allocate.tap do |d|
      d.instance_variable_set(:@path, @path)
      d.instance_variable_set(:@project_config, { 'path' => @path })
      d.instance_variable_set(:@config, config)
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

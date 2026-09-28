# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'post_completion_fixtures'

# Autodev #114. `post_completion`'s precondition survives its own work:
# `start_post_completion!` -> `post_completion_done!` returns the row to `done`,
# and neither of the pass's GitLab gates (still assigned? MR still open?) is moved
# by a deploy. So `dispatch_done_unassigned` re-ran the command on every cycle —
# every 120 s in production — for as long as the MR stayed open.
#
# The pass now reserves the delivery at enqueue (`post_completion_dispatched_at`,
# a compare-and-set like `reserve_infra_recheck?`), the reservation stands
# whatever the outcome, and every path back into work lifts it.
#
# This file holds the pass; its lifecycle — what lifts the reservation, what
# does not, and the job that runs under it — is
# `test/a_post_completion_reservation_is_one_deliverys_test.rb`.
class PostCompletionRunsOnceTest < Minitest::Test
  include DatabaseTestHelper
  include PostCompletionFixtures

  # The defect itself: two cycles, no job in between, one enqueue.
  def test_two_cycles_enqueue_one_hook
    issue = delivered

    assert_equal([[PROJECT_CONFIG['path'], issue.issue_iid, :post_completion]], cycles(2).map { |a| a.first(3) })
  end

  # The job carries the stamp it was reserved under, so it can tell it apart.
  def test_the_job_carries_its_reservation
    issue = delivered
    enqueued = cycles(1)

    assert_equal issue.reload.post_completion_dispatched_at.to_i, enqueued.first.last
  end

  # The dispatcher owns the reservation: the row is stamped before any job runs.
  def test_the_dispatcher_stamps_the_row_it_enqueues
    issue = delivered
    cycles(1)

    refute_nil issue.reload.post_completion_dispatched_at
  end

  # The job's own round trip (done -> running_post_completion -> done) is what
  # the old guard could not see; the stamp survives it, so the next cycle is quiet.
  def test_a_hook_that_ran_is_not_dispatched_again
    issue = delivered
    cycles(1)
    issue.reload.start_post_completion!
    issue.post_completion_done!

    assert_empty cycles(1)
  end

  # One attempt per delivery, whatever the outcome.
  def test_a_hook_that_failed_is_not_dispatched_again
    issue = delivered
    cycles(1)
    issue.update!(post_completion_error: 'post_completion exited 1')

    assert_empty cycles(1)
  end

  # The reservation comes after the gates: a deferred row must be served later.
  def test_a_row_deferred_by_a_locked_mr_is_not_stamped
    issue = delivered

    assert_empty cycles(1, StubClient.new(mr_state: 'locked'))
    assert_nil issue.reload.post_completion_dispatched_at
    assert_equal 1, cycles(1).size
  end

  def test_a_row_still_assigned_is_not_stamped
    issue = delivered

    assert_empty cycles(1, StubClient.new(assignee_ids: [AUTODEV_ID]))
    assert_nil issue.reload.post_completion_dispatched_at
    assert_equal 1, cycles(1).size
  end

  def test_a_merged_mr_is_not_stamped
    issue = delivered

    assert_empty cycles(1, StubClient.new(mr_state: 'merged'))
    assert_nil issue.reload.post_completion_dispatched_at
  end

  # Compare-and-set: whoever stamped first wins, the loser enqueues nothing.
  def test_the_losing_racer_does_not_reserve
    issue = delivered
    d = dispatcher

    assert d.send(:reserve_post_completion?, issue)
    refute d.send(:reserve_post_completion?, issue)
  end

  # The reservation is of *this* delivery: a row that left `done` in between is
  # not stamped by a racer that read it before.
  def test_a_row_no_longer_done_is_not_reserved
    issue = delivered
    Issue.where(id: issue.id).update_all(status: 'checking_pipeline')

    refute dispatcher.send(:reserve_post_completion?, issue)
    assert_nil issue.reload.post_completion_dispatched_at
  end

  def test_a_flagged_row_is_not_reserved
    issue = delivered(needs_attention: true, attention_reason: 'stagnation_pipeline')

    refute dispatcher.send(:reserve_post_completion?, issue)
  end

  # Concurrency review: the stamp and the job live in two databases. An enqueue
  # that fails must not leave a reservation no job will ever serve.
  def test_a_failed_enqueue_lifts_the_reservation
    issue = delivered

    IssueProcessJob.stub(:perform_later, ->(*) { raise ActiveRecord::StatementTimeout }) do
      assert_raises(ActiveRecord::StatementTimeout) { dispatcher.send(:dispatch_done_unassigned) }
    end

    assert_nil issue.reload.post_completion_dispatched_at
    assert_equal 1, cycles(1).size
  end

  def test_a_stamped_row_costs_no_gitlab_read
    delivered(post_completion_dispatched_at: Time.current)
    client = CountingClient.new

    assert_empty cycles(1, client)
    assert_equal 0, client.reads
  end
end

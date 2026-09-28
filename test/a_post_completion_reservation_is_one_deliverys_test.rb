# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'post_completion_fixtures'

# Autodev #114/#94. The `post_completion` reservation belongs to one delivery:
# it survives a restart (an interrupted hook is not re-executed), it is lifted by
# every path back into work together with that delivery's error, and the job only
# runs under the reservation it was enqueued with. The job's return to `done` is
# unconditional, on a raise too (Autodev #94 item 3).
class APostCompletionReservationIsOneDeliverysTest < Minitest::Test
  include DatabaseTestHelper
  include PostCompletionFixtures

  # --- a restart does not lift it: an interrupted hook is not re-executed ---

  def test_a_revived_hook_keeps_its_reservation
    issue = delivered(post_completion_dispatched_at: 1.hour.ago)
    Issue.where(id: issue.id).update_all(status: 'running_post_completion')
    Issue.revive_stalled!(Issue.all)

    assert_equal 'done', issue.reload.status
    refute_nil issue.post_completion_dispatched_at
    assert_empty cycles(1)
  end

  def test_startup_recovery_keeps_the_reservation
    issue = delivered(post_completion_dispatched_at: 1.hour.ago)
    Issue.where(id: issue.id).update_all(status: 'running_post_completion')
    Issue.recover_on_startup!(max_retries: 5)

    refute_nil issue.reload.post_completion_dispatched_at
    assert_empty cycles(1)
  end

  # --- every path back into work lifts the reservation and its verdict ---

  def stamped_with_error
    delivered(post_completion_dispatched_at: Time.current, post_completion_error: 'exited 1')
  end

  def assert_lifted(issue)
    issue.reload

    assert_nil issue.post_completion_dispatched_at
    assert_nil issue.post_completion_error
  end

  def test_a_reentry_through_the_pipeline_check_lifts_it
    issue = stamped_with_error
    resume_handler.send(:reenter_via_pipeline_check, issue)

    assert_equal 'checking_pipeline', issue.reload.status
    assert_lifted(issue)
  end

  def test_a_reentry_through_reimplementation_lifts_it
    issue = stamped_with_error
    resume_handler.send(:reenter_via_reimplementation, nil, issue)

    assert_lifted(issue)
  end

  def test_a_reset_lifts_it
    issue = stamped_with_error
    Issue.reset_for_retry!(Issue.where(id: issue.id), reset_budget: true, clear_attention: true)

    assert_lifted(issue)
  end

  # --- the return to `done` is unconditional (Autodev #94 item 3) ---

  def reserved
    delivered(post_completion_dispatched_at: Time.current)
  end

  def test_a_hook_that_raises_still_returns_the_row_to_done
    issue = reserved

    assert_raises(RuntimeError) { perform_hook(issue) { |*| raise 'boom' } }
    assert_equal 'done', issue.reload.status
  end

  def test_a_hook_that_returns_leaves_the_row_done
    issue = reserved
    perform_hook(issue) { |*| nil }

    assert_equal 'done', issue.reload.status
  end

  def test_a_job_without_its_reservation_runs_nothing
    issue = delivered
    runs = 0
    perform_hook(issue) { |*| runs += 1 }

    assert_equal 0, runs
  end

  # Plan review: a job still queued across a reentry and a second delivery. The
  # held job must not deploy the new delivery, which the next cycle reserves for
  # itself — exactly one run in total.
  def test_a_job_held_across_a_redelivery_does_not_deploy_it
    issue = delivered
    held = cycles(1)
    redeliver(issue)
    runs = [] # the hook runs with the stand-in monitor as `self`, so no ivar
    perform_hook(issue.reload) { |*| runs << :held }
    fresh = cycles(1)
    fresh.each { perform_hook(issue.reload) { |*| runs << :fresh } }

    assert_equal [1, 1, [:fresh]], [held.size, fresh.size, runs]
  end

  # ...and a lifted row is served again once it is delivered again.
  def test_a_new_delivery_gets_its_hook
    redeliver(stamped_with_error)

    assert_equal 1, cycles(1).size
  end
end

# frozen_string_literal: true

require_relative '../rails_helper'

# `Issue.reset_for_retry!` — the single source of truth for putting a row back
# into a state the poller will actually pick up again (Autodev #34, item 3).
#
# Three call sites used to re-derive this rule independently and disagreed:
# the CLI `--reset` got it right, `Issue.recover_errored!` forgot the
# `next_retry_at` stamp on its pre-MR branch, and `IssuesController#reset`
# forgot both the stamp and the MR split.
#
# The rule, in full:
# - a row that already has an MR resumes at `checking_pipeline`, which
#   `dispatch_pipelines` polls unconditionally;
# - a pre-MR row restarts as `pending` AND must have `next_retry_at` stamped,
#   because the GitLab label is still `label_doing` so `dispatch_new_issues`
#   never rediscovers it, and `fetch_retryable` requires a non-NULL stamp.
#   Without it the row is orphaned in `pending` — task #26's exact pattern.
class ResetForRetryTest < ActiveSupport::TestCase
  def errored(overrides = {})
    Issue.create!({ project_path: 'group/proj', issue_iid: rand(10_000..99_999),
                    status: 'error', error_message: 'boom', retry_count: 2 }.merge(overrides))
  end

  def reset!(issue, **)
    Issue.reset_for_retry!(Issue.where(id: issue.id), **)
    issue.reload
  end

  # --- the MR split -------------------------------------------------

  def test_a_row_with_an_mr_resumes_at_checking_pipeline
    issue = reset!(errored(mr_iid: 42))

    assert_equal 'checking_pipeline', issue.status
  end

  def test_a_pre_mr_row_restarts_as_pending
    issue = reset!(errored(mr_iid: nil))

    assert_equal 'pending', issue.status
  end

  # --- the stamp that makes it discoverable -------------------------

  def test_a_pre_mr_row_is_stamped_so_the_poller_sees_it
    issue = reset!(errored(mr_iid: nil))

    assert_not_nil issue.next_retry_at, 'without the stamp fetch_retryable skips it forever (#26)'
    assert_operator issue.next_retry_at, :<=, Time.current
  end

  # checking_pipeline is polled by dispatch_pipelines, which ignores
  # next_retry_at — so a stale stamp would only be noise.
  def test_a_row_with_an_mr_needs_no_stamp
    issue = reset!(errored(mr_iid: 42, next_retry_at: 1.hour.ago))

    assert_nil issue.next_retry_at
  end

  # --- the budget ---------------------------------------------------

  # An operator asking for a reset wants a clean slate.
  def test_reset_budget_clears_the_retry_count
    issue = reset!(errored, reset_budget: true)

    assert_equal 0, issue.retry_count
  end

  # Automatic crash recovery must NOT hand out a fresh budget, or a genuinely
  # broken ticket would restart on every single boot.
  def test_the_budget_is_preserved_by_default
    issue = reset!(errored(retry_count: 2))

    assert_equal 2, issue.retry_count
  end

  # `review_failure_count` joins `reset_budget:` (Autodev #107): it is a
  # budget like `retry_count`, and the dashboard's Reset button used to leave
  # it untouched — a request abandoned at 5/5 stayed at 5/5 after a reset and
  # gave itself up on the very next stumble, with no way for the operator who
  # clicked to know that.
  def test_reset_budget_clears_the_review_failure_count
    issue = reset!(errored(review_failure_count: 5), reset_budget: true)

    assert_equal 0, issue.review_failure_count
  end

  # The automatic revivals (`recover_on_startup!`, `dispatch_dormant_audit`)
  # do not pass `reset_budget:`, and must not clear a budget they did not
  # decide to clear.
  def test_the_review_failure_count_is_preserved_by_default
    issue = reset!(errored(review_failure_count: 5))

    assert_equal 5, issue.review_failure_count
  end

  # --- attention flags ----------------------------------------------

  def test_clear_attention_clears_the_needs_attention_trio
    issue = reset!(errored(needs_attention: true, attention_reason: 'stagnation_pipeline',
                           attention_detail: 'x', mr_iid: nil), clear_attention: true)

    assert_nil issue.attention_reason
    assert_not issue.needs_attention
  end

  def test_attention_flags_are_left_alone_by_default
    issue = reset!(errored(needs_attention: true, attention_reason: 'stagnation_pipeline'))

    assert issue.needs_attention
  end

  # --- always cleared -----------------------------------------------

  def test_the_error_message_is_cleared
    issue = reset!(errored(error_message: 'boom'))

    assert_nil issue.error_message
  end

  # --- startup recovery goes through it -----------------------------

  # The orphan my max_retries fix made selectable: status error, budget spent
  # at the boundary, next_retry_at NULL, no MR. Before, recover_errored! moved
  # it to `pending` without a stamp — still orphaned, just in another state.
  def test_startup_recovery_stamps_the_pre_mr_orphan
    issue = errored(retry_count: 1, next_retry_at: nil, mr_iid: nil)

    Issue.recover_on_startup!(max_retries: 1)

    assert_not_nil issue.reload.next_retry_at, 'recover_errored! must stamp its pre-MR branch too'
  end

  def test_startup_recovery_does_not_hand_out_a_fresh_budget
    issue = errored(retry_count: 1, next_retry_at: nil, mr_iid: nil)

    Issue.recover_on_startup!(max_retries: 1)

    assert_equal 1, issue.reload.retry_count
  end
end

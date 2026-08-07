# frozen_string_literal: true

require_relative '../rails_helper'

# `Issue.revive_stalled!` — the single rule for putting a frozen active row back
# on a path the poller walks (Autodev #47).
#
# Two call sites need it and they must not disagree: `recover_on_startup!` (a
# worker died and the service restarted) and `dispatch_dormant_audit` (a worker
# was pruned and the service did NOT restart — FailedJobReaper discards the job
# and no pass re-dispatches those states).
#
# The rules are deliberately not uniform. `running_post_completion` carries an
# MR but must finish as `done`: the hook is non-fatal and must not be replayed.
# Re-deriving that per call site is how you get a row redoing a review round.
class ReviveStalledTest < ActiveSupport::TestCase
  def stalled(status, overrides = {})
    Issue.create!({ project_path: 'group/proj', issue_iid: rand(10_000..99_999),
                    status: status }.merge(overrides))
  end

  def revive!(issue)
    Issue.revive_stalled!(Issue.where(id: issue.id))
    issue.reload
  end

  # --- pre-MR states restart as pending, and must be discoverable ----

  def test_a_pre_mr_implementing_row_restarts_as_pending
    issue = revive!(stalled('implementing', mr_iid: nil))

    assert_equal 'pending', issue.status
  end

  # Without the stamp, fetch_retryable skips it and dispatch_new_issues never
  # sees it either (the label is still label_doing) — #26's orphan pattern.
  def test_a_pre_mr_row_is_stamped
    issue = revive!(stalled('implementing', mr_iid: nil))

    assert_not_nil issue.next_retry_at
  end

  def test_answering_question_restarts_as_pending
    issue = revive!(stalled('answering_question', mr_iid: nil))

    assert_equal 'pending', issue.status
  end

  # --- post-MR states resume at checking_pipeline --------------------

  def test_a_row_with_an_mr_resumes_at_checking_pipeline
    issue = revive!(stalled('implementing', mr_iid: 42))

    assert_equal 'checking_pipeline', issue.status
  end

  def test_reviewing_resumes_at_checking_pipeline
    issue = revive!(stalled('reviewing', mr_iid: 42))

    assert_equal 'checking_pipeline', issue.status
  end

  def test_fixing_pipeline_resumes_at_checking_pipeline
    issue = revive!(stalled('fixing_pipeline', mr_iid: 42))

    assert_equal 'checking_pipeline', issue.status
  end

  # PipelineMonitor re-derives whether unresolved discussions remain, so
  # checking_pipeline is the state that decides rather than assumes.
  def test_fixing_discussions_resumes_at_checking_pipeline
    issue = revive!(stalled('fixing_discussions', mr_iid: 42))

    assert_equal 'checking_pipeline', issue.status
  end

  # --- the exception that justifies the extraction -------------------

  # It carries an MR, so the naive rule would send it to checking_pipeline and
  # make it redo a whole review round. The hook is non-fatal: it ends as done.
  def test_running_post_completion_ends_as_done_not_checking_pipeline
    issue = revive!(stalled('running_post_completion', mr_iid: 42))

    assert_equal 'done', issue.status
  end

  def test_running_post_completion_is_stamped_finished
    issue = revive!(stalled('running_post_completion', mr_iid: 42))

    assert_not_nil issue.finished_at
  end

  # --- untouched states ---------------------------------------------

  def test_a_checking_pipeline_row_is_left_alone
    issue = revive!(stalled('checking_pipeline', mr_iid: 42))

    assert_equal 'checking_pipeline', issue.status
  end

  def test_a_done_row_is_left_alone
    issue = revive!(stalled('done'))

    assert_equal 'done', issue.status
  end

  # --- the other call site goes through it ---------------------------

  def test_startup_recovery_revives_fixing_discussions
    issue = stalled('fixing_discussions', mr_iid: 42)

    Issue.recover_on_startup!(max_retries: 1)

    assert_equal 'checking_pipeline', issue.reload.status
  end

  def test_startup_recovery_revives_answering_question
    issue = stalled('answering_question', mr_iid: nil)

    Issue.recover_on_startup!(max_retries: 1)

    assert_equal 'pending', issue.reload.status
  end

  def test_startup_recovery_still_ends_post_completion_as_done
    issue = stalled('running_post_completion', mr_iid: 42)

    Issue.recover_on_startup!(max_retries: 1)

    assert_equal 'done', issue.reload.status
  end
end

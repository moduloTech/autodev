# frozen_string_literal: true

require_relative '../rails_helper'

# Coverage of Issue.recover_on_startup! / revive_stalled!.
# Regression guard: a pre-MR issue reset to `pending` on startup must be
# stamped with `next_retry_at` so `dispatch_retries` can re-enqueue it via
# `:retry_stuck` — otherwise the GitLab label is still `label_doing`,
# `dispatch_new_issues` never re-discovers it, and the row is orphaned.
class IssueRecoveryTest < ActiveSupport::TestCase
  def test_pre_mr_stuck_issue_resets_to_pending_with_next_retry_at
    issue = Issue.create!(project_path: 'group/proj', issue_iid: 200,
                          status: 'implementing', mr_iid: nil)

    Issue.recover_on_startup!(max_retries: 1)
    issue.reload

    assert_equal 'pending', issue.status
    assert_not_nil issue.next_retry_at, 'next_retry_at must be stamped so dispatch_retries re-enqueues it'
    assert_operator issue.next_retry_at, :<=, Time.current, 'next_retry_at must be due immediately'
  end

  def test_stuck_issue_with_mr_goes_to_checking_pipeline_without_retry_stamp
    issue = Issue.create!(project_path: 'group/proj', issue_iid: 201,
                          status: 'pushing', mr_iid: 42)

    Issue.recover_on_startup!(max_retries: 1)
    issue.reload

    assert_equal 'checking_pipeline', issue.status
    assert_nil issue.next_retry_at, 'MR-bearing issues are re-polled by dispatch_pipelines, no retry stamp needed'
  end
end

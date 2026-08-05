# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# The state the dashboard's "Réinitialiser / Réessayer" button leaves behind
# (Autodev #34, item 3).
#
# It used to force `pending` with `next_retry_at: nil` for every row, which
# meant the button an operator naturally clicks from /errors left the ticket
# orphaned: `fetch_retryable` requires a non-NULL stamp, and
# `dispatch_new_issues` only rediscovers `labels_todo` while an errored ticket
# still carries `label_doing`. It also sent MR-bearing rows back to a full
# re-implementation instead of `checking_pipeline`. Both are now delegated to
# `Issue.reset_for_retry!`, so the web path can't drift from the CLI one again.
class IssuesControllerResetStateTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    @admin = User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)
    sign_in @admin
  end

  def errored(overrides = {})
    Issue.create!({ project_path: 'group/proj', issue_iid: rand(10_000..99_999),
                    status: 'error', error_message: 'boom', retry_count: 2 }.merge(overrides))
  end

  def test_resetting_a_pre_mr_row_stamps_next_retry_at
    issue = errored(mr_iid: nil)
    post "/issues/#{issue.id}/reset"

    assert_equal 'pending', issue.reload.status
    assert_not_nil issue.next_retry_at, 'without the stamp the reset row is orphaned (#26)'
  end

  def test_resetting_a_row_with_an_mr_resumes_at_checking_pipeline
    issue = errored(mr_iid: 42)
    post "/issues/#{issue.id}/reset"

    assert_equal 'checking_pipeline', issue.reload.status
  end

  # An operator-driven reset is an explicit clean slate, unlike automatic
  # startup recovery.
  def test_resetting_clears_the_retry_budget
    issue = errored(mr_iid: nil)
    post "/issues/#{issue.id}/reset"

    assert_equal 0, issue.reload.retry_count
  end

  def test_resetting_clears_the_needs_attention_flags
    issue = errored(mr_iid: nil, needs_attention: true, attention_reason: 'stagnation_pipeline')
    post "/issues/#{issue.id}/reset"
    issue.reload

    assert_not issue.needs_attention
    assert_nil issue.attention_reason
  end
end

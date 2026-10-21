# frozen_string_literal: true

require_relative '../rails_helper'
require 'action_dispatch/testing/integration'
require 'devise'

# A counted event fired by hand from the dashboard's transition menu is progress
# like any other (Autodev #129, #135): the rule lives on the transition, not on
# who fires it. `@_audit_origin == :manual` must not route it elsewhere.
class AForcedProgressReturnsTheDormantBudgetTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers

  setup do
    sign_in User.create!(email: 'admin@modulotech.fr', name: 'Admin', admin: true)
  end

  def test_a_pipeline_fix_forced_from_the_dashboard_returns_the_budget_and_lifts_the_flag
    issue = Issue.create!(project_path: 'group/proj', issue_iid: 501, status: 'fixing_pipeline', mr_iid: 9,
                          dormant_recheck_count: 3, needs_attention: true, attention_reason: 'dormant_exhausted')
    post "/issues/#{issue.id}/transition", params: { event: 'pipeline_fix_done' }
    issue.reload

    assert_equal ['checking_pipeline', false, nil, 0],
                 [issue.status, issue.needs_attention, issue.attention_reason, issue.dormant_recheck_count]
  end
end

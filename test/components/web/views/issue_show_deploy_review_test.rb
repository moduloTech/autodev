# frozen_string_literal: true

require_relative '../../../autodev_test_helper'

# The deploy-review action must be discoverable on *every* issue detail page,
# not only on issues that already have a branch/MR. Autodev #28: a user
# reported "I can't find the button to deploy a ticket" — on an early-lifecycle
# issue (no branch yet) the whole frame was omitted, leaving no button and no
# explanation. The lazy frame is now always rendered; its own endpoint resolves
# availability (and shows a disabled button + reason when there's no branch).
class IssueShowDeployReviewTest < ActiveSupport::TestCase
  include DatabaseTestHelper

  def setup
    setup_database
  end

  def render_show(issue)
    Web::Views::IssueShow.new(
      issue: issue.attributes.symbolize_keys,
      issue_model: issue,
      events: [],
      kpis: Hash.new(0),
      can_close: false,
      locale: :fr,
      csrf_token: 'test-token'
    ).call
  end

  def test_deploy_review_frame_present_on_early_lifecycle_issue_without_branch
    issue = create_issue(status: 'pending', branch_name: nil, mr_iid: nil)
    html = render_show(issue)

    assert_includes html, "deploy-review-#{issue.id}",
                    'the deploy-review frame must render even before a branch exists'
  end

  def test_deploy_review_frame_present_when_branch_exists
    issue = create_issue(status: 'checking_pipeline', branch_name: 'autodev/issue-1')
    html = render_show(issue)

    assert_includes html, "deploy-review-#{issue.id}"
  end
end

# frozen_string_literal: true

require_relative 'autodev_test_helper'

# The delivered_review tab (and its KPI/pill count) surfaces "delivered but
# flagged" issues: done rows that gave up (needs_attention) or whose
# post-completion hook failed. It must NOT pull in clean deliveries or plain
# errors. Shared scope lives in Web::IssuesFilter#delivered_review_scope.
class IssuesFilterDeliveredReviewTest < Minitest::Test
  include DatabaseTestHelper

  # Minimal host for the Web::Helpers mixin (which pulls in IssuesFilter).
  # No current_user → issues_dataset is Issue.all.
  class Host
    include ::Web::Helpers
  end

  def setup
    setup_database
    @h = Host.new
  end

  def test_delivered_review_tab_selects_needs_attention_and_post_completion
    flagged = create_issue(status: 'done', needs_attention: true, attention_reason: 'stagnation_pipeline')
    post_err = create_issue(status: 'done', post_completion_error: 'deploy failed')
    create_issue(status: 'done')   # clean delivery — excluded
    create_issue(status: 'error')  # an error, not a delivery — excluded

    ids = @h.filter_issues({ tab: 'delivered_review' }).map(&:id)

    assert_equal [flagged.id, post_err.id].sort, ids.sort
  end

  def test_tab_counts_includes_delivered_review
    create_issue(status: 'done', needs_attention: true)
    create_issue(status: 'done', post_completion_error: 'x')
    create_issue(status: 'done') # clean — excluded

    assert_equal 2, @h.tab_counts[:delivered_review]
  end

  def test_unknown_tab_falls_back_to_all
    create_issue(status: 'done')
    create_issue(status: 'error')

    assert_equal 2, @h.filter_issues({ tab: 'bogus' }).count
  end
end

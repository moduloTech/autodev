# frozen_string_literal: true

require_relative 'autodev_test_helper'

# Coverage for surfacing "gave-up done" issues (needs_attention) on the web
# dashboard: the synthetic `done_attention` display status and the
# "À surveiller" count that feeds the KPI card + sidebar badge.
class NeedsAttentionDashboardTest < Minitest::Test
  include DatabaseTestHelper

  # Minimal host for the Web::Helpers mixin. No current_user →
  # admin_or_no_session? is true, so issues_dataset is Issue.all.
  class Host
    include ::Web::Helpers
  end

  def setup
    setup_database
    @helper = Host.new
  end

  def test_issue_status_maps_done_with_attention_to_done_attention
    issue = create_issue(status: 'done', needs_attention: true)

    assert_equal 'done_attention', @helper.issue_status(issue)
  end

  def test_issue_status_leaves_clean_done_unchanged
    issue = create_issue(status: 'done')

    assert_equal 'done', @helper.issue_status(issue)
  end

  def test_to_watch_count_includes_needs_attention_done
    create_issue(status: 'done', needs_attention: true)
    create_issue(status: 'error')
    create_issue(status: 'done') # clean delivery — excluded

    assert_equal 2, @helper.to_watch_count
  end

  def test_to_watch_count_excludes_clean_done
    create_issue(status: 'done')

    assert_equal 0, @helper.to_watch_count
  end
end

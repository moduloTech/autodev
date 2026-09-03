# frozen_string_literal: true

require_relative '../../../autodev_test_helper'

# Autodev #103, item 4: the errors tab must distinguish a row that will come
# back on its own from one no pass will ever pick up — both rendered as
# identical `error` cards before this. Reads the same rule
# `DormantAudit#error_arm` audits by.
class ErrorsTabStrandedRowTest < ActiveSupport::TestCase
  include DatabaseTestHelper

  def setup
    setup_database
  end

  def render_for(issue, admin: false)
    Web::Views::Issues.new(
      issues: [issue], total: 1, total_pages: 1, page: 1, per_page: 50,
      filters: {}, tab: 'errors', tab_counts: Hash.new(0), kpis: Hash.new(0),
      closable_ids: Set.new, current_user_admin: admin
    ).call
  end

  # No schedule at all — the shape a 401, or one of the two generic
  # handlers, leaves the row in.
  def test_a_row_with_no_stamp_is_marked_stranded
    issue = create_issue(status: 'error', retry_count: 0, next_retry_at: nil)
    html = render_for(issue)

    assert_includes html, 'cause-status--stranded'
  end

  # A spent budget, even with some (necessarily past) stamp still on the row,
  # is also stranded.
  def test_a_row_past_budget_is_marked_stranded
    issue = create_issue(status: 'error', retry_count: 2, next_retry_at: 1.hour.ago)
    html = render_for(issue)

    assert_includes html, 'cause-status--stranded'
  end

  # Within budget and stamped in the future: it comes back on its own, so it
  # must NOT read as stranded.
  def test_a_row_scheduled_for_retry_is_not_marked_stranded
    issue = create_issue(status: 'error', retry_count: 0, next_retry_at: 1.hour.from_now)
    html = render_for(issue)

    refute_includes html, 'cause-status--stranded'
    assert_includes html, 'cause-status'
  end

  # The distinction is confined to the errors tab — a needs_clarification or
  # delivered_review card must not sprout a retry-status line.
  def test_the_distinction_does_not_leak_into_other_tabs
    issue = create_issue(status: 'needs_clarification')
    html = Web::Views::Issues.new(
      issues: [issue], total: 1, total_pages: 1, page: 1, per_page: 50,
      filters: {}, tab: 'waiting', tab_counts: Hash.new(0), kpis: Hash.new(0),
      closable_ids: Set.new, current_user_admin: false
    ).call

    refute_includes html, 'cause-status'
  end
end

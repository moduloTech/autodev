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

  # The retry time is the only absolute time on the card — everything else
  # goes through `relative_time` — so a UTC rendering had nothing on screen to
  # be compared against and read two hours early in Paris (second neutral
  # review, N8 / first review G6). `activity_time_zone` is the convention this
  # application already has for exactly that.
  def test_the_retry_time_is_rendered_in_the_configured_timezone
    at = Time.utc(2026, 9, 3, 12, 34)
    issue = create_issue(status: 'error', retry_count: 0, next_retry_at: at)

    with_web_timezone('Europe/Paris') do
      assert_includes render_for(issue), '03/09 14:34', 'the operator reads their own working day'
    end
  end

  def test_the_retry_time_is_utc_when_no_timezone_is_configured
    at = Time.utc(2026, 9, 3, 12, 34)
    issue = create_issue(status: 'error', retry_count: 0, next_retry_at: at)

    with_web_timezone(nil) do
      assert_includes render_for(issue), '03/09 12:34'
    end
  end

  private

  def with_web_timezone(name)
    previous = Web.config
    web = (previous['web'] || {}).merge('timezone' => name).compact
    Web.config = previous.merge('web' => web)
    yield
  ensure
    Web.config = previous
  end
end

# frozen_string_literal: true

require_relative '../rails_helper'

# `Issue.without_activity_since` — the single definition of "this row has
# stopped moving", shared by HealthReport's stuck-issues card and by
# `dispatch_dormant_audit` (Autodev #47).
#
# They must not drift: the whole shape of #47 was a card that correctly flagged
# 14 frozen rows while no pass did anything about them. One scope, two readers.
class IssueDormancyTest < ActiveSupport::TestCase
  def issue(overrides = {})
    Issue.create!({ project_path: 'group/proj', issue_iid: rand(10_000..99_999),
                    status: 'pending' }.merge(overrides))
  end

  def event(issue, at)
    ActivityEvent.create!(issue_id: issue.id, kind: 'transition', level: 'info',
                          payload_json: '{}', created_at: at)
  end

  def dormant_ids(cutoff = 1.hour.ago) = Issue.without_activity_since(cutoff).pluck(:id)

  # --- the fallback for rows that never emitted anything ------------

  def test_an_old_row_with_no_activity_is_dormant
    old = issue(created_at: 3.hours.ago)

    assert_includes dormant_ids, old.id
  end

  def test_a_fresh_row_with_no_activity_is_not_dormant
    fresh = issue(created_at: 1.minute.ago)

    assert_not_includes dormant_ids, fresh.id
  end

  # --- rows that have emitted --------------------------------------

  def test_a_row_whose_last_event_is_old_is_dormant
    row = issue(created_at: 3.hours.ago)
    event(row, 2.hours.ago)

    assert_includes dormant_ids, row.id
  end

  def test_a_row_with_a_recent_event_is_not_dormant
    row = issue(created_at: 3.hours.ago)
    event(row, 2.hours.ago)
    event(row, 1.minute.ago)

    assert_not_includes dormant_ids, row.id
  end

  # --- the NULL trap ------------------------------------------------

  # activity_events carries issue-less rows (kind 'poller', 'usage'). A naive
  # `WHERE id NOT IN (SELECT issue_id ...)` returns the empty set as soon as one
  # NULL is in the subquery — SQL three-valued logic. This test is the guard.
  def test_issueless_events_do_not_swallow_the_result
    old = issue(created_at: 3.hours.ago)
    ActivityEvent.create!(issue_id: nil, kind: 'poller', level: 'info',
                          payload_json: '{}', created_at: 1.minute.ago)

    assert_includes dormant_ids, old.id
  end

  # --- chainability -------------------------------------------------

  def test_it_chains_after_another_scope
    old = issue(created_at: 3.hours.ago)
    issue(created_at: 3.hours.ago, status: 'error')

    assert_equal [old.id], Issue.where(status: 'pending').without_activity_since(1.hour.ago).pluck(:id)
  end
end

# frozen_string_literal: true

require_relative 'rails_helper'
require_relative 'database_test_helper'

# A re-entry from `done` (or `closed`) starts a new delivery, whichever path
# fires it (the alpha-56 lot's integration review).
#
# `dispatch_done_unassigned` reserves a delivery's `post_completion` hook once
# (Autodev #114), so the reservation and that delivery's error must not outlive
# it. They used to be cleared only by `reset_for_retry!` and the two
# `ResumeHandler` reentries; the dashboard's transition menu fires `reenter` and
# `reenter_to_check_pipeline` from `done` directly, and the next delivery was
# never deployed. The clear now lives on the two AASM events.
#
# `pending_resolutions` (Autodev #125) says a thread's correction is on the
# branch: `reenter` rebuilds the branch, so it goes; `reenter_to_check_pipeline`
# keeps the MR and its branch, so it stays.
#
# A *manual* re-entry also stamps `label_events_seen_until` (Autodev #101): the
# human asking for it is the answer to "has anybody taken this ticket", like the
# operator Reset. An automatic re-entry is not a statement about the ticket.
class AReentryStartsANewDeliveryTest < Minitest::Test
  include DatabaseTestHelper
  include ActiveSupport::Testing::TimeHelpers

  RESOLUTIONS = '[{"discussion_id":"d1","note_id":1}]'

  def setup = setup_database
  def teardown = travel_back

  def delivered_row
    create_issue(status: 'done', mr_iid: 11, post_completion_dispatched_at: 1.day.ago,
                 post_completion_error: 'post_completion exited with code 1',
                 pending_resolutions: RESOLUTIONS, label_events_seen_until: 20.days.ago)
  end

  def fire(row, event, origin: nil)
    row._audit_origin = origin
    row.public_send(:"#{event}!")
    row.reload
  end

  %i[reenter reenter_to_check_pipeline].each do |event|
    define_method(:"test_#{event}_clears_the_previous_delivery_s_reservation_and_error") do
      row = fire(delivered_row, event)

      assert_equal [nil, nil], [row.post_completion_dispatched_at, row.post_completion_error]
    end

    define_method(:"test_a_manual_#{event}_stamps_the_label_events_floor") do
      freeze_time
      row = fire(delivered_row, event, origin: :manual)

      assert_equal Time.current.to_i, row.label_events_seen_until.to_i
    end

    define_method(:"test_an_automatic_#{event}_leaves_the_label_events_floor_alone") do
      row = delivered_row
      floor = row.label_events_seen_until

      assert_equal floor.to_i, fire(row, event).label_events_seen_until.to_i
    end

    define_method(:"test_#{event}_from_closed_clears_the_reservation_too") do
      row = delivered_row
      row.update_columns(status: 'closed')

      assert_nil fire(row, event).post_completion_dispatched_at
    end
  end

  def test_reenter_drops_the_pending_resolutions_of_the_branch_it_rebuilds
    assert_nil fire(delivered_row, :reenter).pending_resolutions
  end

  def test_reenter_to_check_pipeline_keeps_the_pending_resolutions_of_the_branch_it_keeps
    assert_equal RESOLUTIONS, fire(delivered_row, :reenter_to_check_pipeline).pending_resolutions
  end

  # Out of scope on purpose (the plan): the manual transition gives back no
  # budget. The label resume and the Reset do; this is master's behaviour and
  # changing it is a product decision.
  BUDGETS = { retry_count: 3, review_failure_count: 2, dormant_recheck_count: 3, infra_recheck_count: 4 }.freeze

  %i[reenter reenter_to_check_pipeline].each do |event|
    define_method(:"test_a_manual_#{event}_gives_back_no_budget") do
      row = delivered_row
      row.update_columns(**BUDGETS)

      reentered = fire(row, event, origin: :manual)

      assert_equal(BUDGETS.values, BUDGETS.keys.map { |k| reentered[k] })
    end
  end

  # `ReviewArrearsSweep` fires the event with its origin as an argument.
  def test_an_event_fired_with_an_origin_still_clears_and_records_it
    row = delivered_row
    row.reenter_to_check_pipeline!(PollRouter::REVIEW_ARREARS_ORIGIN)
    row.reload
    payload = JSON.parse(ActivityEvent.where(issue_id: row.id, kind: 'transition').last.payload_json)

    assert_equal [nil, nil, RESOLUTIONS], [row.post_completion_dispatched_at, row.post_completion_error,
                                           row.pending_resolutions]
    assert_equal PollRouter::REVIEW_ARREARS_ORIGIN.to_s, payload['origin']
  end

  # Another event leaves every one of these fields where it was.
  def test_another_event_touches_none_of_them
    row = delivered_row
    row._audit_origin = :manual
    row.start_post_completion!
    row.reload

    assert_equal [RESOLUTIONS, 'post_completion exited with code 1'],
                 [row.pending_resolutions, row.post_completion_error]
    refute_nil row.post_completion_dispatched_at
    assert_operator row.label_events_seen_until, :<, 1.day.ago
  end
end

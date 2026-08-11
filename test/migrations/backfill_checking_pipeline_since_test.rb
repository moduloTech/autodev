# frozen_string_literal: true

require_relative '../test_helper'

# Without a backfill, every row stuck in `checking_pipeline` at upgrade time
# would start a fresh 14-day grace at the release — including production's
# #15894, whose 29 773 poll events are the reason the ticket exists. The last
# `transition` activity event *is* the last transition, so it reconstructs the
# real entry instant; `issues.created_at` is the fallback for a row that has
# none (Autodev #53).
class BackfillCheckingPipelineSinceTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
  end

  def migrate!
    AddCheckingPipelineSinceToIssues.new.up
  end

  def watched(created_at: 30.days.ago)
    issue = create_issue(status: 'checking_pipeline', mr_iid: 3)
    issue.update_columns(created_at: created_at, checking_pipeline_since: nil)
    issue
  end

  def transition_event(issue, at)
    ActivityEvent.create!(issue_id: issue.id, kind: 'transition', level: 'info',
                          payload_json: '{"from":"creating_mr","to":"checking_pipeline"}')
                 .update_columns(created_at: at)
  end

  def test_the_stamp_comes_from_the_newest_transition_event
    issue = watched
    transition_event(issue, 20.days.ago)
    transition_event(issue, 4.days.ago)

    migrate!

    assert_in_delta 4.days.ago.to_i, issue.reload.checking_pipeline_since.to_i, 60
  end

  def test_a_row_without_transition_events_falls_back_to_its_creation
    issue = watched(created_at: 12.days.ago)

    migrate!

    assert_in_delta 12.days.ago.to_i, issue.reload.checking_pipeline_since.to_i, 60
  end

  # Only `danger_claude` polls exist on the worst offenders; they say nothing
  # about when the row entered the state.
  def test_poll_events_do_not_count_as_transitions
    issue = watched(created_at: 30.days.ago)
    ActivityEvent.create!(issue_id: issue.id, kind: 'danger_claude', level: 'info',
                          payload_json: '{"key":"pipeline_checking"}')

    migrate!

    assert_in_delta 30.days.ago.to_i, issue.reload.checking_pipeline_since.to_i, 60
  end

  def test_a_row_in_another_state_is_left_alone
    issue = create_issue(status: 'implementing')

    migrate!

    assert_nil issue.reload.checking_pipeline_since
  end

  def test_re_running_does_not_move_an_existing_stamp
    issue = watched
    transition_event(issue, 4.days.ago)
    migrate!
    stamp = issue.reload.checking_pipeline_since

    migrate!

    assert_equal stamp, issue.reload.checking_pipeline_since
  end
end

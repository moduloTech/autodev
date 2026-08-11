# frozen_string_literal: true

require_relative 'test_helper'

require 'autodev/activity_logger'

# What collapsing the per-poll activity row (Autodev #53) does — and does not do
# — to the invariant Autodev #50 built on `Issue.without_activity_since`:
#
#   > the scope counts EVERY activity_events row for the issue, and is the one
#   > definition of "this row has stopped moving" shared by DormantAudit's
#   > active arm and HealthReport's "Issues bloquées" card.
#
# The active arm mutates by `update_all`, inline in the poll cycle, outside the
# `limits_concurrency` that serialises IssueProcessJob — so a row that merely
# *looks* silent can be repositioned under a live worker. Two independent things
# have to hold, and each gets its own half of this file:
#
#   1. collapsing preserves freshness (the row still carries an event from the
#      last poll), so the scope's inputs are unchanged;
#   2. no reader looks at a `checking_pipeline` row anyway — the state is in
#      neither `Issue::STALLED_STATES` nor either half of HealthReport's card.
#
# (2) alone would make the change safe today. It is pinned here rather than
# relied upon: it is a fact about constants defined elsewhere, for other
# reasons, and the day one of them changes the silence becomes load-bearing.
class PipelineWatchInvariantTest < Minitest::Test
  include DatabaseTestHelper

  FakeNote = Struct.new(:id, :body)

  class FakeClient
    def initialize = @body = 'header line'
    def create_issue_note(_path, _iid, body) = FakeNote.new(7, @body = body)
    def issue_note(_path, _iid, _note_id) = FakeNote.new(7, @body)
    def edit_issue_note(_path, _iid, note_id, body) = FakeNote.new(note_id, @body = body)
  end

  POLL_PATTERN = /— :mag:.*(?:pipeline|statut du pipeline)/

  def setup
    setup_database
    @ctx = ActivityLogger::Ctx.new(FakeClient.new, 'g/p', nil)
  end

  def watched_issue
    issue = create_issue(status: 'checking_pipeline', mr_iid: 12)
    issue.update_columns(created_at: 30.days.ago)
    issue
  end

  def poll(issue)
    ActivityLogger.post(@ctx, issue, :pipeline_checking, since: '08-01 10:00',
                                                         replace_pattern: POLL_PATTERN)
  end

  # --- 1. collapsing preserves freshness ----------------------------------

  def test_a_repeatedly_polled_row_keeps_one_event_carrying_the_last_poll
    issue = watched_issue
    5.times { poll(issue) }
    events = ActivityEvent.where(issue_id: issue.id).to_a

    assert_equal 1, events.size
    assert_operator events.first.created_at, :>, 1.minute.ago
  end

  # The load-bearing assertion: before the collapse this row had 5 rows, all
  # fresh; after it, one row, still fresh. The scope must not see a difference.
  def test_a_freshly_polled_row_is_not_dormant
    issue = watched_issue
    5.times { poll(issue) }

    refute_includes Issue.without_activity_since(1.hour.ago).pluck(:id), issue.id
  end

  def test_a_row_whose_last_poll_is_old_is_still_dormant
    issue = watched_issue
    poll(issue)
    ActivityEvent.where(issue_id: issue.id).update_all(created_at: 3.hours.ago)

    assert_includes Issue.without_activity_since(1.hour.ago).pluck(:id), issue.id
  end

  # Unlike a heartbeat, a poll entry is real activity someone asked to see: it
  # is the "still watching since X" line of the GitLab thread.
  def test_a_collapsed_poll_row_stays_user_visible
    issue = watched_issue
    poll(issue)

    assert_equal 1, ActivityEvent.user_visible.where(issue_id: issue.id).count
  end

  # --- 2. no reader looks at a checking_pipeline row ----------------------

  # If this ever fails, a watched row became revivable and the collapse's
  # freshness guarantee (part 1) becomes the only thing standing between
  # `dispatch_dormant_audit` and a row a live worker holds. Read part 1 before
  # changing the constant.
  def test_checking_pipeline_is_not_a_stalled_state
    refute_includes Issue::STALLED_STATES, 'checking_pipeline'
  end

  # Same reasoning for the card the audit shares its windows with: it excludes
  # the state on purpose ("waits on an external pipeline, re-polled every
  # cycle"), and the exclusion is what makes a quiet watched row a non-event.
  def test_checking_pipeline_is_flagged_by_neither_half_of_the_stuck_card
    refute_includes Autodev::HealthReport::ACTIVE_STUCK_STATES, 'checking_pipeline'
    refute_includes Autodev::HealthReport::PENDING_STUCK_STATES, 'checking_pipeline'
  end

  def test_the_stuck_card_does_not_flag_a_silent_watched_row
    watched_issue # no activity at all, created 30 days ago
    report = Autodev::HealthReport.new(config: {}, poller_expected: false).call

    assert_equal 0, report[:checks][:stuck_issues][:meta][:count]
  end

  # End-to-end over the real query rather than the constant: a watched row with
  # no activity for a week is not a dormant-audit candidate.
  def test_the_dormant_audit_never_selects_a_silent_watched_row
    watched_issue
    audit = Autodev::DormantAudit.new(client: nil, path: 'group/project', config: {},
                                      project_config: {}, logger: nil)

    assert_empty audit.candidates
  end
end

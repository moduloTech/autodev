# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'

# Which rows the dormant audit picks up (Autodev #47 + #48).
#
# Three populations, one bound. A `pending` row with next_retry_at NULL is
# invisible to dispatch_new_issues (it carries label_doing, not labels_todo)
# AND to dispatch_retries (which requires the stamp) — that is #47, 14 rows
# frozen on powerpanne/core, the oldest since April 13th. An `error` row with a
# spent budget is #34's population, unchanged. An active row with no activity
# for 2h is a pruned worker: FailedJobReaper discards the job and no pass
# re-dispatches those states.
class DormantAuditSelectionTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_CONFIG = { 'path' => 'group/project', 'max_retries' => 1 }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example',
             'poll_interval' => 300 }.freeze

  StubClient = Class.new

  def setup
    setup_database
    @logger = StubLogger.new
  end

  def audit(config: CONFIG, project_config: PROJECT_CONFIG)
    Autodev::DormantAudit.new(client: StubClient.new, path: project_config['path'],
                              config: config, project_config: project_config, logger: @logger)
  end

  def candidate_iids(**) = audit(**).candidates.map(&:issue_iid)

  # The pending window is HealthReport's poller-staleness one:
  # max(poll_interval * 3, 900) = 900s here. Two hours is safely past it.
  def orphan(overrides = {})
    create_issue({ status: 'pending', next_retry_at: nil,
                   created_at: 2.hours.ago }.merge(overrides))
  end

  def spent(overrides = {})
    create_issue({ status: 'error', retry_count: 2, created_at: 2.hours.ago }.merge(overrides))
  end

  def frozen_active(overrides = {})
    create_issue({ status: 'implementing', created_at: 4.hours.ago }.merge(overrides))
  end

  # --- the pending arm (#47) ----------------------------------------

  def test_an_orphaned_pending_row_is_a_candidate
    issue = orphan

    assert_includes candidate_iids, issue.issue_iid
  end

  # It already has a path forward: dispatch_retries picks it up on the stamp.
  def test_a_stamped_pending_row_is_not
    issue = orphan(next_retry_at: 1.hour.ago)

    refute_includes candidate_iids, issue.issue_iid
  end

  # find_or_create_issue creates the row with next_retry_at NULL and enqueues
  # :process right after. Auditing it in that gap would burn a bounded attempt
  # on a ticket that never had its chance.
  def test_a_freshly_created_pending_row_is_not
    issue = orphan(created_at: 1.minute.ago)

    refute_includes candidate_iids, issue.issue_iid
  end

  def test_a_pending_row_with_recent_activity_is_not
    issue = orphan
    ActivityEvent.create!(issue_id: issue.id, kind: 'transition', level: 'info',
                          payload_json: '{}', created_at: 1.minute.ago)

    refute_includes candidate_iids, issue.issue_iid
  end

  # --- the error arm (#34, unchanged) -------------------------------

  def test_a_spent_budget_error_row_is_a_candidate
    issue = spent

    assert_includes candidate_iids, issue.issue_iid
  end

  # Still inside its budget: dispatch_retries owns it. Picking it up here too
  # would double-dispatch the same ticket.
  def test_an_error_row_still_within_budget_is_not
    issue = spent(retry_count: 1)

    refute_includes candidate_iids, issue.issue_iid
  end

  # --- the active arm (#47, the FailedJobReaper gap) ----------------

  def test_an_active_row_frozen_for_hours_is_a_candidate
    issue = frozen_active

    assert_includes candidate_iids, issue.issue_iid
  end

  def test_an_active_row_still_emitting_activity_is_not
    issue = frozen_active
    ActivityEvent.create!(issue_id: issue.id, kind: 'danger_claude', level: 'info',
                          payload_json: '{}', created_at: 10.minutes.ago)

    refute_includes candidate_iids, issue.issue_iid
  end

  # checking_pipeline waits on an external pipeline and is re-polled every
  # cycle — the documented "no blocked state". It is not stalled.
  def test_a_checking_pipeline_row_is_never_a_candidate
    issue = create_issue(status: 'checking_pipeline', mr_iid: 42, created_at: 4.hours.ago)

    refute_includes candidate_iids, issue.issue_iid
  end

  def test_a_done_row_is_never_a_candidate
    issue = create_issue(status: 'done', created_at: 4.hours.ago)

    refute_includes candidate_iids, issue.issue_iid
  end

  # --- the shared bound ---------------------------------------------

  def test_a_row_at_the_cap_is_excluded
    issue = orphan(dormant_recheck_count: Autodev::PollDispatcher::DEFAULT_DORMANT_AUDIT_MAX)

    refute_includes candidate_iids, issue.issue_iid
  end

  def test_a_row_inside_its_backoff_is_excluded
    issue = orphan(dormant_recheck_count: 1, dormant_recheck_at: 1.hour.from_now)

    refute_includes candidate_iids, issue.issue_iid
  end

  def test_a_row_whose_backoff_elapsed_is_included
    issue = orphan(dormant_recheck_count: 1, dormant_recheck_at: 1.hour.ago)

    assert_includes candidate_iids, issue.issue_iid
  end

  def test_the_cap_is_configurable
    issue = orphan(dormant_recheck_count: 2)

    refute_includes candidate_iids(config: CONFIG.merge('dormant_audit_max' => 2)), issue.issue_iid
  end

  # A production config.yml tuned for #34 expressed a policy, not a column name.
  def test_the_legacy_error_recheck_key_still_applies
    issue = orphan(dormant_recheck_count: 2)

    refute_includes candidate_iids(config: CONFIG.merge('error_recheck_max' => 2)), issue.issue_iid
  end

  # --- scoping ------------------------------------------------------

  def test_another_project_is_not_swept
    issue = orphan(project_path: 'other/project')

    refute_includes candidate_iids, issue.issue_iid
  end

  # --- the invariant #47 is really about -----------------------------

  # The stuck-issues card flagged all 14 frozen rows correctly and nothing acted
  # on them. Anything that card reports, in this project and under cap, must be
  # a candidate here — otherwise the two drift apart again and the card goes
  # back to being a report nobody can act on.
  def test_everything_healthreport_calls_stuck_is_a_candidate
    orphan
    create_issue(status: 'implementing', created_at: 4.hours.ago)
    report = Autodev::HealthReport.new(config: CONFIG)
    flagged = report.send(:stuck_issues).select { |i| i.project_path == PROJECT_CONFIG['path'] }

    assert_predicate flagged, :any?, 'fixture must produce at least one stuck row'
    assert_empty flagged.map(&:issue_iid) - candidate_iids
  end
end

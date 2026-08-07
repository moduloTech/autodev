# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/activity_logger'

# What the dormant audit does with GitLab's answer (Autodev #47 + #48).
#
# One read, three outcomes. Closure wins over unassignment (a closed ticket is
# closed whether or not it is still assigned), and both win over re-arming —
# which is the whole point of #48 landing with #47 rather than after it: the two
# real cases found on 2026-08-06 were a ticket closed on GitLab (#16207) and one
# handed back to a human (#15909), both still sitting in `pending`. Re-arming
# either would have restarted work that is no longer ours.
class DormantAuditRoutingTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_CONFIG = { 'path' => 'group/project', 'max_retries' => 1 }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example',
             'poll_interval' => 300 }.freeze
  AUTODEV_ID = 7

  FakeUser = Struct.new(:id)
  FakeAssignee = Struct.new(:id)
  FakeIssue = Struct.new(:state, :assignees)

  class StubClient
    attr_reader :calls

    def initialize(state: 'opened', assignee_ids: [AUTODEV_ID])
      @state = state
      @assignee_ids = assignee_ids
      @calls = 0
    end

    def user = FakeUser.new(AUTODEV_ID)

    def issue(_project, _iid)
      @calls += 1
      FakeIssue.new(@state, @assignee_ids.map { |id| FakeAssignee.new(id) })
    end
  end

  def setup
    setup_database
    @logger = StubLogger.new
    GitlabHelpers.instance_variable_set(:@current_user_id, AUTODEV_ID)
  end

  def run_audit(issue, client: StubClient.new, config: CONFIG)
    Autodev::DormantAudit.new(client: client, path: PROJECT_CONFIG['path'], config: config,
                              project_config: PROJECT_CONFIG, logger: @logger).run
    issue.reload
  end

  def orphan(overrides = {})
    create_issue({ status: 'pending', next_retry_at: nil, created_at: 2.hours.ago }.merge(overrides))
  end

  def spent(overrides = {})
    create_issue({ status: 'error', retry_count: 2, created_at: 2.hours.ago }.merge(overrides))
  end

  # --- outcome 1: closed on GitLab (#16207) -------------------------

  def test_a_closed_pending_row_is_closed_locally
    issue = run_audit(orphan, client: StubClient.new(state: 'closed'))

    assert_equal 'closed', issue.status
  end

  def test_a_closed_error_row_is_closed_locally
    issue = run_audit(spent, client: StubClient.new(state: 'closed'))

    assert_equal 'closed', issue.status
  end

  def test_a_closed_row_is_not_rearmed
    issue = run_audit(spent, client: StubClient.new(state: 'closed'))

    assert_equal 2, issue.retry_count
  end

  # Closure wins: `closed` says more than `done`.
  def test_a_closed_and_unassigned_row_is_closed_not_done
    issue = run_audit(orphan, client: StubClient.new(state: 'closed', assignee_ids: [999]))

    assert_equal 'closed', issue.status
  end

  # --- outcome 2: handed back to a human (#15909) -------------------

  def test_an_unassigned_pending_row_goes_to_done
    issue = run_audit(orphan, client: StubClient.new(assignee_ids: [999]))

    assert_equal 'done', issue.status
  end

  def test_an_unassigned_row_is_not_rearmed
    issue = run_audit(spent, client: StubClient.new(assignee_ids: [999]))

    assert_equal 2, issue.retry_count
  end

  # --- outcome 3: still ours -----------------------------------------

  def test_an_orphaned_pending_row_gets_a_due_stamp
    issue = run_audit(orphan)

    assert_equal 'pending', issue.status
    refute_nil issue.next_retry_at
    assert_operator issue.next_retry_at, :<=, Time.current
  end

  def test_a_spent_error_row_gets_its_budget_back
    issue = run_audit(spent)

    assert_equal 0, issue.retry_count
    refute_nil issue.next_retry_at
  end

  # A pruned worker left it mid-implementation; revive_stalled! owns the rules.
  def test_a_frozen_pre_mr_active_row_restarts_as_pending
    issue = run_audit(create_issue(status: 'implementing', mr_iid: nil, created_at: 4.hours.ago))

    assert_equal 'pending', issue.status
    refute_nil issue.next_retry_at
  end

  def test_a_frozen_post_mr_active_row_resumes_at_checking_pipeline
    issue = run_audit(create_issue(status: 'implementing', mr_iid: 42, created_at: 4.hours.ago))

    assert_equal 'checking_pipeline', issue.status
  end

  # --- the bound ------------------------------------------------------

  def test_auditing_costs_one_attempt_and_backs_off
    issue = run_audit(orphan)

    assert_equal 1, issue.dormant_recheck_count
    assert_operator issue.dormant_recheck_at, :>, Time.current
  end

  # Declining costs an attempt too, or a forgotten ticket makes us call GitLab
  # on every single poll forever.
  def test_declining_still_costs_an_attempt
    issue = run_audit(spent, client: StubClient.new(state: 'closed'))

    assert_equal 1, issue.dormant_recheck_count
  end

  def test_one_gitlab_read_per_candidate
    client = StubClient.new
    orphan
    Autodev::DormantAudit.new(client: client, path: PROJECT_CONFIG['path'], config: CONFIG,
                              project_config: PROJECT_CONFIG, logger: @logger).run

    assert_equal 1, client.calls
  end

  # --- resilience -----------------------------------------------------

  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  class FailingClient < StubClient
    def issue(_project, _iid)
      raise Gitlab::Error::ResponseError,
            FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/issues'))
    end
  end

  def test_a_gitlab_error_leaves_the_status_untouched
    issue = run_audit(orphan, client: FailingClient.new)

    assert_equal 'pending', issue.status
  end

  # The counter is bumped before the read on purpose: an unreachable project
  # burns the cap instead of being retried on every cycle forever.
  def test_a_gitlab_error_still_costs_an_attempt
    issue = run_audit(orphan, client: FailingClient.new)

    assert_equal 1, issue.dormant_recheck_count
  end
end

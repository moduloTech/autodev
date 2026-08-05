# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'

# Bounded second-chance recovery for tickets whose retry budget is spent
# (Autodev #34, follow-up of #33).
#
# Exhausting `max_retries` is the right outcome for a genuine code failure, but
# not for a transient one — a network blip, a GitLab/registry outage, the
# `git push` stale-info case from #33. Those used to be terminal: nothing ever
# re-attempted the row once the cause disappeared (same orphan pattern #31
# fixed for infra stagnations).
#
# `dispatch_error_recheck` does NOT reimplement the retry mechanics: it simply
# **re-arms the spent budget** (retry_count back to 0 + a due `next_retry_at`)
# at most `error_recheck_max` times, spaced by a long backoff, and lets the
# existing `dispatch_retries` → `:retry_errored` / `:retry_stuck` path do the
# work — labels, activity log and all. It deliberately does not classify the
# error: JobClassifier reads GitLab CI `failure_reason` values, not Ruby
# exceptions, so classifying here would mean a new brittle heuristic over
# `error_message`. A real code failure instead burns the cap — a few extra
# rounds spread over hours — and then rests terminal, which is the bound the
# ticket asked for.
class ErrorRecheckDispatchTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_CONFIG = { 'path' => 'group/project', 'max_retries' => 1 }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example' }.freeze
  AUTODEV_ID = 7

  FakeUser = Struct.new(:id)
  FakeAssignee = Struct.new(:id)
  FakeIssue = Struct.new(:assignees, :state)

  class StubClient
    def initialize(assignee_ids: [AUTODEV_ID], state: 'opened')
      @assignee_ids = assignee_ids
      @state = state
    end

    def user = FakeUser.new(AUTODEV_ID)

    def issue(_project, _iid)
      FakeIssue.new(@assignee_ids.map { |id| FakeAssignee.new(id) }, @state)
    end
  end

  def setup
    setup_database
    @logger = StubLogger.new
    # GitlabHelpers.current_user_id memoizes at module level; keep the id
    # stable across tests rather than fighting it.
    GitlabHelpers.instance_variable_set(:@current_user_id, AUTODEV_ID)
  end

  def dispatcher(project_config: PROJECT_CONFIG, config: CONFIG, client: StubClient.new)
    Autodev::PollDispatcher.allocate.tap do |d|
      d.instance_variable_set(:@path, project_config['path'])
      d.instance_variable_set(:@project_config, project_config)
      d.instance_variable_set(:@config, config)
      d.instance_variable_set(:@logger, @logger)
      d.instance_variable_set(:@client, client)
    end
  end

  def candidate_iids(**)
    dispatcher(**).send(:fetch_error_recheck_candidates).map(&:issue_iid)
  end

  # Budget spent: max_retries is 1, so retry_count 2 is past it.
  def spent(overrides = {})
    create_issue({ status: 'error', retry_count: 2, next_retry_at: nil }.merge(overrides))
  end

  # --- candidate query ---------------------------------------------

  def test_selects_a_spent_under_cap_backoff_elapsed_error
    issue = spent

    assert_includes candidate_iids, issue.issue_iid
  end

  # A row still inside its budget belongs to dispatch_retries, not here —
  # picking it up too would double-dispatch the same ticket.
  def test_excludes_a_row_still_within_budget
    issue = spent(retry_count: 1)

    refute_includes candidate_iids, issue.issue_iid
  end

  def test_excludes_when_the_cap_is_reached
    issue = spent(error_recheck_count: Autodev::PollDispatcher::DEFAULT_ERROR_RECHECK_MAX)

    refute_includes candidate_iids, issue.issue_iid
  end

  def test_excludes_when_the_backoff_is_still_running
    issue = spent(error_recheck_at: 1.hour.from_now)

    refute_includes candidate_iids, issue.issue_iid
  end

  def test_selects_once_the_backoff_has_elapsed
    issue = spent(error_recheck_count: 1, error_recheck_at: 1.hour.ago)

    assert_includes candidate_iids, issue.issue_iid
  end

  def test_excludes_a_row_that_is_not_in_error
    issue = spent(status: 'done')

    refute_includes candidate_iids, issue.issue_iid
  end

  def test_the_cap_is_configurable
    issue = spent(error_recheck_count: 2)

    refute_includes candidate_iids(config: CONFIG.merge('error_recheck_max' => 2)), issue.issue_iid
  end

  # --- re-arming ----------------------------------------------------

  def rearm(issue, client: StubClient.new)
    dispatcher(client: client).send(:dispatch_error_recheck)
    issue.reload
  end

  def test_rearming_resets_the_spent_budget
    issue = rearm(spent)

    assert_equal 0, issue.retry_count
  end

  # Without a due next_retry_at, fetch_retryable skips the row and the
  # re-arm would be silently useless (the #26 orphan pattern).
  def test_rearming_stamps_a_due_next_retry_at
    issue = rearm(spent)

    refute_nil issue.next_retry_at
    assert_operator issue.next_retry_at, :<=, Time.current
  end

  def test_rearming_costs_one_attempt_and_backs_off
    issue = rearm(spent)

    assert_equal 1, issue.error_recheck_count
    assert_operator issue.error_recheck_at, :>, Time.current
  end

  # --- worth it? ----------------------------------------------------

  def test_an_unassigned_ticket_is_not_rearmed
    issue = rearm(spent, client: StubClient.new(assignee_ids: [999]))

    assert_equal 2, issue.retry_count
  end

  def test_a_closed_ticket_is_not_rearmed
    issue = rearm(spent, client: StubClient.new(state: 'closed'))

    assert_equal 2, issue.retry_count
  end

  # Still bounded even when we decline, so an unassigned-and-forgotten row
  # cannot make us call GitLab on every single poll forever.
  def test_declining_still_costs_an_attempt
    issue = rearm(spent, client: StubClient.new(state: 'closed'))

    assert_equal 1, issue.error_recheck_count
  end
end

# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'

# Autodev #103's core claim: `PollDispatcher.retryable?` and
# `DormantAudit#error_arm` describe one question — "will a pass pick this row
# up?" — and must be asked from the same rule, or a gap opens between them the
# way it did for a row that errors on a 401: no stamp, budget unspent,
# selected by neither.
#
# Asserted against the two predicates directly, rather than against
# hand-written column values, so a future edit to either side that reopens
# the gap fails here first.
class RetryableAndDormantAreComplementsTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_CONFIG = { 'path' => 'group/project', 'max_retries' => 1 }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example',
             'poll_interval' => 300 }.freeze
  MAX_RETRIES = 1

  def setup
    setup_database
    @logger = StubLogger.new
  end

  def audit
    Autodev::DormantAudit.new(client: Object.new, path: PROJECT_CONFIG['path'], config: CONFIG,
                              project_config: PROJECT_CONFIG, logger: @logger)
  end

  def dormant_iids = audit.send(:error_arm).map(&:issue_iid)

  # Old enough that the age guard never excludes it — the age guard is
  # exercised on its own in dormant_audit_selection_test.rb.
  def error_row(overrides = {})
    create_issue({ status: 'error', created_at: 2.hours.ago }.merge(overrides))
  end

  # A row `PollDispatcher.retryable?` selects is never in the dormant
  # population — the two must never claim the same row at once.
  def test_a_retryable_row_is_never_dormant
    issue = error_row(retry_count: 1, next_retry_at: 1.minute.ago)

    assert Autodev::PollDispatcher.retryable?(issue, max_retries: MAX_RETRIES, now: Time.current)
    refute_includes dormant_iids, issue.issue_iid
  end

  # A row that will NEVER become retryable — a spent budget, or no schedule
  # at all — is always dormant. This is the regression: the old arm only
  # covered the first half.
  def test_a_row_that_will_never_retry_is_always_dormant
    issue = error_row(retry_count: 1, next_retry_at: nil)

    refute Autodev::PollDispatcher.retryable?(issue, max_retries: MAX_RETRIES, now: Time.current)
    assert_includes dormant_iids, issue.issue_iid
  end

  def test_an_over_budget_row_is_always_dormant
    issue = error_row(retry_count: 2, next_retry_at: nil)

    refute Autodev::PollDispatcher.retryable?(issue, max_retries: MAX_RETRIES, now: Time.current)
    assert_includes dormant_iids, issue.issue_iid
  end

  # A future stamp inside budget is not retryable *now*, but it is not
  # dormant either — it is waiting, and time alone will make it retryable.
  # This is the one case a bare negation of `retryable?` would get wrong.
  def test_a_future_stamp_within_budget_is_neither_retryable_nor_dormant
    issue = error_row(retry_count: 1, next_retry_at: 1.hour.from_now)

    refute Autodev::PollDispatcher.retryable?(issue, max_retries: MAX_RETRIES, now: Time.current)
    refute_includes dormant_iids, issue.issue_iid
  end
end

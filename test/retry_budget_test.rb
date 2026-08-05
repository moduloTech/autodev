# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/danger_claude_runner'
require 'autodev/issue_notifier'
require 'autodev/label_manager'
require 'autodev/activity_logger'
require 'autodev/issue_processor'

# `max_retries` is a budget of RETRIES, not of total attempts (Autodev #34).
#
# It used to be compared with a strict `<` at every site, so a budget of N
# allowed only N-1 retries — and since the baked default is 1
# (Config::DEFAULTS, and a *global* YAML value is ignored via
# IGNORED_GLOBAL_FIELDS, so only a per-project override can raise it), the
# common case allowed **zero**: the first failure left `next_retry_at` NULL,
# `fetch_retryable` skipped the row forever, `dispatch_new_issues` never
# rediscovered it (it still carries `label_doing`), and even
# `recover_errored!` filtered it out at startup. Every first error orphaned
# its ticket permanently, which is what was observed in prod on #36.
#
# The three former call sites also each carried their own fallback (`|| 3` in
# ErrorHandler, none at all — i.e. 0 — in PollDispatcher), so they disagreed
# on the budget whenever the key was absent. `Config.max_retries` is now the
# single source of truth.
class RetryBudgetTest < Minitest::Test
  include DatabaseTestHelper

  PROJECT_CONFIG = { 'path' => 'group/project' }.freeze
  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example' }.freeze

  def setup
    setup_database
    @logger = StubLogger.new
  end

  # --- single source of truth --------------------------------------

  def test_defaults_to_the_baked_default_when_nothing_overrides_it
    assert_equal Config::DEFAULTS['max_retries'], Config.max_retries({}, {})
  end

  def test_a_per_project_override_wins
    assert_equal 5, Config.max_retries({ 'max_retries' => 5 }, { 'max_retries' => 2 })
  end

  def test_falls_back_to_the_global_value_without_a_project_override
    assert_equal 2, Config.max_retries({}, { 'max_retries' => 2 })
  end

  # A missing key must never resolve to 0 — that was PollDispatcher's silent
  # behaviour (`nil.to_i`), which disabled retries wholesale.
  def test_never_resolves_to_zero
    assert_operator Config.max_retries(nil, nil), :>=, 1
  end

  # --- the budget counts retries ------------------------------------

  def dispatcher(project_config: PROJECT_CONFIG, config: CONFIG)
    Autodev::PollDispatcher.allocate.tap do |d|
      d.instance_variable_set(:@path, project_config['path'])
      d.instance_variable_set(:@project_config, project_config)
      d.instance_variable_set(:@config, config)
      d.instance_variable_set(:@logger, @logger)
    end
  end

  def retryable_iids(**)
    dispatcher(**).send(:fetch_retryable).map(&:issue_iid)
  end

  def errored(overrides = {})
    create_issue({ status: 'error', retry_count: 1, next_retry_at: 1.minute.ago }.merge(overrides))
  end

  # The case from #34: budget 1, one failure recorded. It has spent no retry
  # yet, so it must still be picked up.
  def test_a_row_at_the_budget_is_still_retryable
    issue = errored(retry_count: 1)

    assert_includes retryable_iids(project_config: PROJECT_CONFIG.merge('max_retries' => 1)),
                    issue.issue_iid
  end

  def test_a_row_past_the_budget_is_not_retryable
    issue = errored(retry_count: 2)

    refute_includes retryable_iids(project_config: PROJECT_CONFIG.merge('max_retries' => 1)),
                    issue.issue_iid
  end

  def test_exceeded_retries_is_false_at_the_budget
    issue = errored(retry_count: 1)

    refute dispatcher(project_config: PROJECT_CONFIG.merge('max_retries' => 1))
      .send(:exceeded_retries?, issue)
  end

  def test_exceeded_retries_is_true_past_the_budget
    issue = errored(retry_count: 2)

    assert dispatcher(project_config: PROJECT_CONFIG.merge('max_retries' => 1))
      .send(:exceeded_retries?, issue)
  end

  # --- the failure path stamps a retry ------------------------------

  # The crux of #34: with the default budget, the FIRST failure must still
  # stamp `next_retry_at`, otherwise nothing ever re-enqueues the row.
  def test_the_first_failure_stamps_a_next_retry_at_under_the_default_budget
    fields = error_fields(retry_count_before: 0, project_config: PROJECT_CONFIG)

    refute_nil fields[:next_retry_at]
  end

  def test_a_failure_past_the_budget_stamps_no_retry
    fields = error_fields(retry_count_before: 1, project_config: PROJECT_CONFIG.merge('max_retries' => 1))

    assert_nil fields[:next_retry_at]
  end

  def test_the_failure_increments_the_retry_count
    fields = error_fields(retry_count_before: 0, project_config: PROJECT_CONFIG)

    assert_equal 1, fields[:retry_count]
  end

  # --- startup recovery --------------------------------------------

  # `recover_errored!` accepts a NULL `next_retry_at`, so it was the one path
  # that could have rescued these orphans — the same strict `<` excluded them.
  def test_startup_recovery_rescues_an_orphan_at_the_budget
    issue = errored(retry_count: 1, next_retry_at: nil, mr_iid: nil)

    Issue.recover_on_startup!(max_retries: 1)

    assert_equal 'pending', issue.reload.status
  end

  def test_startup_recovery_leaves_a_row_past_the_budget_in_error
    issue = errored(retry_count: 2, next_retry_at: nil, mr_iid: nil)

    Issue.recover_on_startup!(max_retries: 1)

    assert_equal 'error', issue.reload.status
  end

  private

  def error_fields(retry_count_before:, project_config:)
    issue = errored(retry_count: retry_count_before)
    processor = IssueProcessor.allocate
    processor.instance_variable_set(:@project_config, project_config)
    processor.instance_variable_set(:@config, CONFIG)
    processor.instance_variable_set(:@dc_stdout, nil)
    processor.instance_variable_set(:@dc_stderr, nil)
    processor.send(:build_error_fields, issue, RuntimeError.new('boom'), nil)
  end
end

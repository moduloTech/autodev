# frozen_string_literal: true

require_relative 'rails_helper'
require_relative 'database_test_helper'

# Which path runs, and what each one does to the counters (Autodev #74).
class ReviewSkillPathTest < ActiveSupport::TestCase
  include DatabaseTestHelper

  def setup = setup_database

  def monitor(review_skill:, skill_result: true, binary_called: [])
    mon = PipelineMonitor.allocate
    mon.instance_variable_set(:@project_path, 'g/a')
    mon.instance_variable_set(:@project_config, review_skill ? { 'review_skill' => review_skill } : {})
    %i[log log_error].each { |m| mon.define_singleton_method(m) { |*| nil } }
    mon.define_singleton_method(:log_activity) { |*| nil }
    mon.define_singleton_method(:snapshot) { |*| nil }
    mon.define_singleton_method(:review_with_skill) { |_| skill_result }
    mon.define_singleton_method(:execute_mr_review) { |_| binary_called << true and true }
    mon
  end

  def issue
    Issue.create!(project_path: 'g/a', issue_iid: 1, mr_iid: 7, status: 'reviewing',
                  review_count: 0, review_failure_count: 0, locale: 'fr')
  end

  def test_a_project_with_a_review_skill_does_not_run_the_binary
    called = []
    row = issue
    monitor(review_skill: 'mr-review', binary_called: called).send(:launch_review, row)

    assert_empty called
    assert_equal 1, row.reload.review_count
  end

  def test_a_project_without_a_review_skill_runs_the_binary
    called = []
    monitor(review_skill: nil, binary_called: called).send(:launch_review, issue)

    assert_equal [true], called
  end

  def test_a_skill_review_failure_increments_the_failure_counter
    row = issue
    monitor(review_skill: 'mr-review', skill_result: false).send(:launch_review, row)

    assert_equal 1, row.reload.review_failure_count
    assert_equal 0, row.reload.review_count
  end

  def test_an_inconclusive_review_touches_neither_counter_and_returns_to_the_watch
    row = issue
    monitor(review_skill: 'mr-review', skill_result: :inconclusive).send(:launch_review, row)

    assert_equal 0, row.reload.review_count
    assert_equal 0, row.reload.review_failure_count
    assert_equal 'checking_pipeline', row.reload.status
  end

  def test_an_api_failure_while_publishing_burns_no_budget
    row = issue
    mon = monitor(review_skill: 'mr-review')
    mon.define_singleton_method(:review_with_skill) do |_|
      raise ApiUnavailableError.new(:mr_note, StandardError.new('boom'))
    end
    assert_raises(ApiUnavailableError) { mon.send(:launch_review, row) }
    assert_equal 0, row.reload.review_failure_count
    assert_equal 0, row.reload.review_count
  end

  # The counters were the whole of the assertion above, and they were already
  # right — which is why the defect this pins was invisible. `green_first_review`
  # fires `pipeline_green!` *before* `launch_review`, so the row is in `reviewing`
  # when a GitLab error escapes the publish, and no dispatch pass selects
  # `reviewing`: recovery fell to `DormantAudit` two hours later and spent one of
  # three `dormant_audit_max` attempts. An outage must not spend a budget
  # (Autodev #71) — including that one.
  def test_an_api_failure_while_publishing_hands_the_row_back_to_the_watch
    row = issue
    mon = monitor(review_skill: 'mr-review')
    mon.define_singleton_method(:review_with_skill) do |_|
      raise ApiUnavailableError.new(:mr_note, StandardError.new('boom'))
    end
    assert_raises(ApiUnavailableError) { mon.send(:launch_review, row) }
    assert_equal 'checking_pipeline', row.reload.status
  end

  # `check_dc_failures!` runs inside `danger_claude_prompt`, so the skill path can
  # raise `RateLimitError` where the binary path never could. Every other
  # `danger_claude_prompt` call site answers it with `handle_rate_limit`
  # (`IssueProcessor`, `FailureHandler`, `FixCycle`); this one answered it by
  # letting the row sit in `reviewing`.
  def test_a_claude_rate_limit_parks_the_row_for_a_dated_retry
    row = issue
    mon = monitor(review_skill: 'mr-review')
    mon.define_singleton_method(:review_with_skill) { |_| raise RateLimitError, 'quota' }
    mon.send(:launch_review, row)

    assert_equal 'error', row.reload.status
    refute_nil row.reload.next_retry_at
    assert_equal 0, row.reload.review_failure_count
  end

  # Same source, other class. `AutodevError` is a sibling tree, so
  # `rescue RateLimitError` cannot cover it, and no generic handler stands on this
  # path the way `handle_failure_error` / `handle_fix_error` do on the fix trees.
  # Dead Claude credentials are a standing misconfiguration: `error`, no retry
  # scheduled, and the dashboard's 401 card reads the class name off
  # `error_message`.
  def test_a_dead_claude_credential_lands_in_error_not_in_reviewing
    row = issue
    mon = monitor(review_skill: 'mr-review')
    mon.define_singleton_method(:review_with_skill) { |_| raise AuthenticationError, 'API 401' }
    mon.send(:launch_review, row)

    assert_equal 'error', row.reload.status
    assert_includes row.reload.error_message.to_s, 'AuthenticationError'
  end

  # A recorded ruling, pinned so nobody "improves" it: a declared skill missing
  # from the clone keeps escaping. Rescuing it and handing the row back would
  # write an activity row every poll, which keeps the row out of `DormantAudit`'s
  # active arm forever *and* restarts the age clock — a genuinely unbounded,
  # unsignalled loop. Parking in `reviewing` is the better of the two available
  # behaviours: `DormantAudit` gives it three bounded second looks and then flags
  # `dormant_exhausted`.
  def test_a_missing_declared_skill_still_escapes_and_leaves_the_row_in_reviewing
    row = issue
    mon = monitor(review_skill: 'mr-review')
    mon.define_singleton_method(:review_with_skill) { |_| raise ConfigError, 'skill missing' }

    assert_raises(ConfigError) { mon.send(:launch_review, row) }
    assert_equal 'reviewing', row.reload.status
  end

  # `''` is truthy in Ruby, so a YAML-only project that spells the key with an
  # empty value took the skill path with an empty skill name — a clone, a
  # danger-claude run and a prompt naming no skill at all.
  def test_a_blank_review_skill_reads_as_absent_and_runs_the_binary
    called = []
    monitor(review_skill: '', binary_called: called).send(:launch_review, issue)

    assert_equal [true], called
  end
end

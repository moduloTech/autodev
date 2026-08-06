# frozen_string_literal: true

require_relative 'test_helper'
require 'json'
require 'autodev/pipeline_monitor'

# Autodev #46 — `:check_pipeline` keeps running during a Claude quota outage, so
# PipelineMonitor holds the gate at the two points where it would call Claude:
#
#   * a green pipeline with `review_count == 0` launches mr-review;
#   * a red pipeline with a code verdict clones and calls danger-claude.
#
# Both must leave the ticket exactly where it is — in `checking_pipeline`, with
# no counter, signature or activity line touched — so the next cycle picks it up
# unchanged once the quota is back.
class PipelineMonitorUsageGateTest < Minitest::Test
  # Minimal Issue stand-in (same shape as pipeline_monitor_infra_stagnation_test).
  class FakeIssue
    attr_reader :attrs, :issue_iid, :mr_iid, :mr_url, :review_count
    attr_accessor :stagnation_signatures, :pipeline_poll_since,
                  :_review_count_zero, :_review_count_over_zero,
                  :_max_review_rounds_reached, :_unresolved_discussions_empty

    def initialize(review_count: 0, stagnation_signatures: nil)
      @review_count = review_count
      @stagnation_signatures = stagnation_signatures
      @issue_iid = 4242
      @mr_iid = 42
      @mr_url = 'http://mr'
      @attrs = {}
    end

    def update(hash)
      @attrs.merge!(hash)
      @stagnation_signatures = hash[:stagnation_signatures] if hash.key?(:stagnation_signatures)
      @pipeline_poll_since = hash[:pipeline_poll_since] if hash.key?(:pipeline_poll_since)
      self
    end

    def done? = false
  end

  NOOPS = %i[log log_error clear_pipeline_poll_since].freeze

  # Records every side effect the gated branches would otherwise produce.
  def monitor(available:, config: {})
    sink = { activity: [], reviewed: [], fixed: [] }
    m = PipelineMonitor.allocate
    m.instance_variable_set(:@project_config, {})
    m.instance_variable_set(:@config, config)
    NOOPS.each { |noop| m.define_singleton_method(noop) { |*| nil } }
    m.define_singleton_method(:claude_available?) { available }
    stub_sinks(m, sink)
    [m, sink]
  end

  def stub_sinks(mon, sink)
    mon.define_singleton_method(:log_activity) { |_issue, key, **vars| sink[:activity] << [key, vars] }
    mon.define_singleton_method(:launch_review) { |issue| sink[:reviewed] << issue.issue_iid }
    mon.define_singleton_method(:clone_and_fix) { |issue, *| sink[:fixed] << issue.issue_iid }
  end

  # --- green pipeline, first review --------------------------------------

  def test_an_exhausted_quota_does_not_launch_mr_review
    m, sink = monitor(available: false)
    m.send(:handle_green, FakeIssue.new(review_count: 0))

    assert_empty sink[:reviewed]
  end

  # The ticket must stay in checking_pipeline: no AASM event fires, so a
  # FakeIssue without `pipeline_green!` is proof enough — the call would raise.
  def test_an_exhausted_quota_leaves_the_ticket_in_checking_pipeline
    m, = monitor(available: false)

    m.send(:handle_green, FakeIssue.new(review_count: 0)) # no NoMethodError = no transition
  end

  # The gate sits before log_activity on purpose: a note appended on every poll
  # would blow past GitLab's 1M-char cap over a long outage.
  def test_an_exhausted_quota_writes_no_activity_line
    m, sink = monitor(available: false)
    m.send(:handle_green, FakeIssue.new(review_count: 0))

    assert_empty sink[:activity]
  end

  def test_a_healthy_quota_still_launches_mr_review
    m, sink = monitor(available: true)
    issue = FakeIssue.new(review_count: 0)
    issue.define_singleton_method(:pipeline_green!) { nil }
    m.send(:handle_green, issue)

    assert_equal [issue.issue_iid], sink[:reviewed]
  end

  # Only the first review consumes Claude. A green pipeline that has already
  # been reviewed just finalizes — it must not be gated.
  def test_an_exhausted_quota_does_not_block_a_post_review_green
    m, sink = monitor(available: false)
    issue = FakeIssue.new(review_count: 1)
    issue.define_singleton_method(:pipeline_green!) { nil }
    m.define_singleton_method(:fetch_unresolved_discussions) { |_iid| [] }
    m.define_singleton_method(:snapshot) { |*| nil }
    m.send(:handle_green, issue)

    refute_empty sink[:activity]
  end

  # --- red pipeline, code verdict ----------------------------------------

  def failed_jobs
    [{ 'name' => 'rspec', 'stage' => 'test', 'failure_reason' => 'script_failure' }]
  end

  def run_triage(available:, stagnation_signatures: nil)
    m, sink = monitor(available: available, config: { 'stagnation_threshold' => 5 })
    m.define_singleton_method(:pre_triage) { |_jobs| { verdict: :code, explanation: 'boom' } }
    issue = FakeIssue.new(stagnation_signatures: stagnation_signatures)
    m.send(:triage_and_fix, issue, nil, failed_jobs)
    [issue, sink]
  end

  def test_an_exhausted_quota_does_not_clone_and_fix
    _issue, sink = run_triage(available: false)

    assert_empty sink[:fixed]
  end

  # A cycle that never even looked at the failure must not count towards
  # stagnation, or an outage would burn the whole budget and give up.
  def test_an_exhausted_quota_leaves_the_stagnation_signature_alone
    issue, = run_triage(available: false)

    assert_nil issue.stagnation_signatures
  end

  def test_a_healthy_quota_still_fixes_and_counts
    issue, sink = run_triage(available: true)

    assert_equal [issue.issue_iid], sink[:fixed]
    assert_equal 1, JSON.parse(issue.stagnation_signatures).dig('pipeline', 'count')
  end
end

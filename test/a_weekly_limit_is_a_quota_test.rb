# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/danger_claude_runner'
require 'autodev/issue_notifier'
require 'autodev/pipeline_monitor'
require 'autodev/mr_fixer'
require 'autodev/issue_processor'

# Autodev #127 — A#144's path, end to end from danger-claude's answer.
#
# On 2026-09-26 at 02:59 UTC, four rows asked danger-claude for a correction
# and got back claude's JSON envelope carrying "You've hit your weekly limit ·
# resets Oct 1, 3am (UTC)", with a non-zero exit. The wording was not
# recognised, so `danger_claude_prompt` raised a plain ImplementationError:
# `error` with no retry, and a public ":x: echec correction MR" (MrFixer, A#142,
# A#144, A#145) or "echec de la correction du pipeline" (PipelineMonitor, A#137)
# on each ticket. What is pinned here is the outcome on each worker: the quota
# park — `error`, `next_retry_at` at the reset the message names, a
# `rate_limit` entry — and nothing posted.
#
# Real: `danger_claude_prompt` (envelope parsing, `check_dc_failures!`), each
# worker's rescue routing, its `handle_rate_limit`, the state machine and the
# row. Stubbed: the process spawn, the GitLab note, the activity-log writer.
class AWeeklyLimitIsAQuotaTest < ActiveSupport::TestCase
  include DatabaseTestHelper

  # The envelope persisted in A#144's activity trail, trimmed to the fields
  # `capture_session_and_text` reads.
  ENVELOPE = JSON.generate(
    'type' => 'result', 'is_error' => true, 'num_turns' => 29,
    'result' => "You've hit your weekly limit · resets Oct 1, 3am (UTC)",
    'stop_reason' => 'stop_sequence', 'session_id' => 'bb4d0c1e-0000-4000-8000-000000000000'
  )
  NOW = Time.utc(2026, 9, 26, 2, 59, 54)
  RESET = Time.utc(2026, 10, 1, 3, 0, 0)

  def setup
    setup_database
    @notified = []
    @activity = []
  end

  def worker(klass)
    w = klass.allocate
    w.instance_variable_set(:@project_path, 'group/project')
    w.instance_variable_set(:@project_config, {})
    w.instance_variable_set(:@config, {})
    w.instance_variable_set(:@logger, StubLogger.new)
    w.instance_variable_set(:@dc_stdout, +'')
    w.instance_variable_set(:@dc_stderr, +'')
    stub_side_effects(w)
    w
  end

  def stub_side_effects(worker)
    notified = @notified
    activity = @activity
    worker.define_singleton_method(:run_with_timeout) { |*, **| [ENVELOPE, '', false] }
    worker.define_singleton_method(:dc_global_args) { |**| [] }
    worker.define_singleton_method(:dc_heartbeat!) { |*| nil }
    worker.define_singleton_method(:notify_localized) { |_iid, key, **| notified << key }
    worker.define_singleton_method(:log_activity) { |_issue, key, **| activity << key }
  end

  def assert_parked(issue)
    issue.reload

    assert_equal 'error', issue.status
    assert_equal RESET, issue.next_retry_at, issue.error_message.to_s[0, 400]
    assert_equal 1, issue.retry_count, 'a quota spends no retry, and gives none back'
    assert_empty @notified, 'a quota must post nothing on the ticket'
    assert_equal [:rate_limit], @activity
  end

  test 'an MR correction that meets the weekly limit is parked until the reset, silently' do
    issue = create_issue(status: 'fixing_discussions', mr_iid: 11_333, retry_count: 1)
    mr_fixer = worker(MrFixer)
    mr_fixer.define_singleton_method(:run_fix_cycle) { |*| danger_claude_prompt('/tmp', 'fix the thread') }

    travel_to(NOW) { mr_fixer.send(:execute_fix_cycle, issue, []) }

    assert_parked(issue)
  end

  test 'a pipeline correction that meets the weekly limit is parked until the reset, silently' do
    issue = create_issue(status: 'fixing_pipeline', mr_iid: 11_424, retry_count: 1)
    monitor = worker(PipelineMonitor)
    monitor.define_singleton_method(:triage_and_fix) { |*| danger_claude_prompt('/tmp', 'fix the thread') }

    travel_to(NOW) { monitor.send(:attempt_fix, issue, nil, []) }

    assert_parked(issue)
  end

  test 'an implementation that meets the weekly limit is parked until the reset, silently' do
    issue = create_issue(status: 'implementing', retry_count: 1)
    processor = worker(IssueProcessor)
    processor.define_singleton_method(:start_processing) { |*| nil }
    processor.define_singleton_method(:issue_closed?) { |*| false }
    processor.define_singleton_method(:execute_pipeline) { |*| danger_claude_prompt('/tmp', 'fix the thread') }

    travel_to(NOW) { processor.process(issue) }

    assert_parked(issue)
  end

  # The control: the same call failing for a reason that is not a quota still
  # takes the failure path, comment included — the park is not a blanket.
  test 'an MR correction that fails for another reason still reports the failure' do
    issue = create_issue(status: 'fixing_discussions', mr_iid: 11_333)
    mr_fixer = worker(MrFixer)
    failure = JSON.generate('type' => 'result', 'is_error' => true, 'result' => 'Tool execution failed')
    mr_fixer.define_singleton_method(:run_with_timeout) { |*, **| [failure, '', false] }
    mr_fixer.define_singleton_method(:run_fix_cycle) { |*| danger_claude_prompt('/tmp', 'fix the thread') }

    travel_to(NOW) { mr_fixer.send(:execute_fix_cycle, issue, []) }

    assert_equal 'error', issue.reload.status
    assert_nil issue.next_retry_at
    assert_equal [:mr_fix_error], @notified
  end
end

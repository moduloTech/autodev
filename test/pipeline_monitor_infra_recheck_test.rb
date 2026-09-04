# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/pipeline_monitor'

# A ticket that stagnated on an INFRA/deploy failure ends `done` +
# needs_attention (`stagnation_pipeline`) and used never to be re-attempted once
# CI recovered (real case: 17 MRs stayed blocked long after the werf binary was
# fixed). `PipelineMonitor#recheck_infra_recovery` re-classifies the MR's CURRENT
# head pipeline and returns true only when CI has recovered, so the dispatch pass
# can re-enter it. Every non-recovery outcome records one bounded, backed-off
# attempt so the recheck self-limits at the cap and never loops.
class PipelineMonitorInfraRecheckTest < Minitest::Test
  FakeMr = Struct.new(:state, :head_pipeline)
  FakePipeline = Struct.new(:id, :status)

  # Minimal Issue stand-in recording `update` writes.
  class FakeIssue
    attr_reader :attrs, :issue_iid, :mr_iid

    def initialize(issue_iid: 16_081, mr_iid: 42, infra_recheck_count: 0)
      @issue_iid = issue_iid
      @mr_iid = mr_iid
      @attrs = { infra_recheck_count: infra_recheck_count }
    end

    def update(hash)
      @attrs.merge!(hash)
      self
    end

    def infra_recheck_count = @attrs[:infra_recheck_count]
    def infra_recheck_at = @attrs[:infra_recheck_at]
  end

  # GitLab client stub: one MR (with head pipeline) and a fixed failed-job set.
  class StubClient
    def initialize(merge_req:, jobs: [])
      @mr = merge_req
      @jobs = jobs
    end

    def merge_request(_project_path, _mr_iid) = @mr
    def pipeline_jobs(_project_path, _pid, **_opts) = @jobs
  end

  def monitor(client:, project_config: {}, config: {})
    PipelineMonitor.allocate.tap do |m|
      m.instance_variable_set(:@client, client)
      m.instance_variable_set(:@project_path, 'group/project')
      m.instance_variable_set(:@project_config, project_config)
      m.instance_variable_set(:@config, config)
      m.define_singleton_method(:log) { |*| nil }
      m.define_singleton_method(:log_error) { |*| nil }
    end
  end

  def failed_job(name:, stage:, reason:)
    { 'name' => name, 'stage' => stage, 'status' => 'failed',
      'allow_failure' => false, 'failure_reason' => reason }
  end

  def deploy_jobs = [failed_job(name: 'deploy_review', stage: 'deploy', reason: 'script_failure')]
  def code_jobs = [failed_job(name: 'rspec', stage: 'test', reason: 'script_failure')]

  def test_recovered_when_pipeline_green_and_does_not_consume_a_recheck
    mr = FakeMr.new('opened', FakePipeline.new(9, 'success'))
    issue = FakeIssue.new(infra_recheck_count: 2)

    assert monitor(client: StubClient.new(merge_req: mr)).recheck_infra_recovery(issue)
    assert_equal 2, issue.infra_recheck_count, 'a recovery must not burn a recheck attempt'
    assert_nil issue.infra_recheck_at
  end

  def test_recovered_when_no_pipeline_at_all
    mr = FakeMr.new('opened', nil)
    issue = FakeIssue.new

    assert monitor(client: StubClient.new(merge_req: mr)).recheck_infra_recovery(issue)
  end

  # Autodev #110: the backoff stamp moved to
  # `PollDispatcher#reserve_infra_recheck`, which now reserves the row before
  # the job runs. `record_recheck_attempt` owns the counter alone and no
  # longer touches `infra_recheck_at` — this test used to assert the opposite.
  def test_still_infra_failing_does_not_reenter_and_records_the_attempt
    mr = FakeMr.new('opened', FakePipeline.new(9, 'failed'))
    issue = FakeIssue.new(infra_recheck_count: 1)

    refute monitor(client: StubClient.new(merge_req: mr, jobs: deploy_jobs)).recheck_infra_recovery(issue)
    assert_equal 2, issue.infra_recheck_count
    assert_nil issue.infra_recheck_at, 'the dispatcher owns this column now, not the job'
  end

  def test_code_origin_failure_is_left_untouched
    mr = FakeMr.new('opened', FakePipeline.new(9, 'failed'))
    issue = FakeIssue.new

    # Never re-enter a pipeline now failing on code — a real failure to fix by hand.
    refute monitor(client: StubClient.new(merge_req: mr, jobs: code_jobs)).recheck_infra_recovery(issue)
  end

  def test_closed_mr_does_not_reenter
    mr = FakeMr.new('closed', nil)
    issue = FakeIssue.new

    refute monitor(client: StubClient.new(merge_req: mr)).recheck_infra_recovery(issue)
    assert_equal 1, issue.infra_recheck_count
  end

  def test_running_pipeline_waits_without_reentering
    mr = FakeMr.new('opened', FakePipeline.new(9, 'running'))
    issue = FakeIssue.new

    refute monitor(client: StubClient.new(merge_req: mr)).recheck_infra_recovery(issue)
    assert_equal 1, issue.infra_recheck_count
  end

  # Autodev #110: `infra_recheck_backoff` now governs
  # `PollDispatcher#reserve_infra_recheck` alone (see
  # `test/infra_recheck_settings_test.rb` and
  # `test/infra_recheck_reservation_test.rb`) — this test used to assert that
  # `record_recheck_attempt` read the setting and stamped it; it no longer
  # writes the column at all, whatever the config says.
  def test_recording_an_attempt_no_longer_stamps_the_backoff_whatever_the_config
    mr = FakeMr.new('opened', FakePipeline.new(9, 'failed'))
    issue = FakeIssue.new
    m = monitor(client: StubClient.new(merge_req: mr, jobs: deploy_jobs), config: { 'infra_recheck_backoff' => 60 })

    m.recheck_infra_recovery(issue)

    assert_nil issue.infra_recheck_at, 'the dispatcher owns this column now, not the job'
  end

  # Autodev #110, design §2: even with the dispatcher's reservation, the cap is
  # a guard and not only a filter. A write beyond `infra_recheck_max` is
  # refused rather than logged and written — the old code logged `9/5` and
  # wrote it anyway, which is what kept the defect invisible for a night.
  def test_an_attempt_past_the_cap_is_refused_and_not_written
    mr = FakeMr.new('opened', FakePipeline.new(9, 'failed'))
    issue = FakeIssue.new(infra_recheck_count: 5)
    m = monitor(client: StubClient.new(merge_req: mr, jobs: deploy_jobs), config: { 'infra_recheck_max' => 5 })

    refute m.recheck_infra_recovery(issue)

    assert_equal 5, issue.infra_recheck_count, 'a write past the cap must be refused, not clamped'
  end
end

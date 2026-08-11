# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/pipeline_monitor'

# Autodev #51 — a `manual` pipeline is resolved by its blocking jobs.
#
# GitLab reports `manual` when every job that could run has run and what is left
# needs a human. On a project whose MR pipelines end with a manual deploy_review
# that is the NORMAL end state of a green MR, and it used to fall in
# dispatch_status's `else`: log a line, do nothing, forever. Measured on
# powerpanne/core: pipeline 215229 read 12 729 times in 18 days, four tickets
# finished and never delivered until humans relabelled them by hand.
#
# The roll-up status cannot express "the jobs that gate the merge are green, the
# ones that gate a deploy are waiting for a human". The job list can, so the
# verdict is taken there: no blocking job failed → green.
class PipelineMonitorManualStatusTest < Minitest::Test
  FakePipeline = Struct.new(:id, :status)

  # Gitlab::Error::ResponseError builds its message from the real HTTP response
  # (code, parsed_response, request.base_uri + path); this is the minimum
  # surface it reads. The rescue in fetch_pipeline_jobs is narrow, so a plain
  # Gitlab::Error::Error would not exercise it.
  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  # Returns the configured job list, or raises to simulate an API failure.
  class StubClient
    attr_reader :jobs_calls

    def initialize(jobs: [], raise_error: false)
      @jobs = jobs
      @raise_error = raise_error
      @jobs_calls = 0
    end

    def pipeline_jobs(_project_path, _pid, **_opts)
      @jobs_calls += 1
      if @raise_error
        raise Gitlab::Error::ResponseError,
              FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/jobs'))
      end

      @jobs
    end
  end

  FakeIssue = Struct.new(:issue_iid, :mr_iid)

  # Records the routing decision instead of running the real green/red paths.
  def monitor(client:)
    sink = { green: [], red: [] }
    m = PipelineMonitor.allocate
    m.instance_variable_set(:@client, client)
    m.instance_variable_set(:@project_path, 'group/project')
    m.instance_variable_set(:@project_config, {})
    m.instance_variable_set(:@config, {})
    stub_sinks(m, sink)
    [m, sink]
  end

  def stub_sinks(mon, sink)
    mon.define_singleton_method(:log) { |*| nil }
    mon.define_singleton_method(:log_error) { |*| nil }
    mon.define_singleton_method(:handle_green) { |issue| sink[:green] << issue.issue_iid }
    mon.define_singleton_method(:handle_red) { |issue, pipeline| sink[:red] << [issue.issue_iid, pipeline] }
  end

  def job(status:, allow_failure: false, name: 'test')
    { 'name' => name, 'stage' => 'test', 'status' => status, 'allow_failure' => allow_failure }
  end

  def dispatch(jobs: [], status: 'manual', client: nil)
    client ||= StubClient.new(jobs: jobs)
    m, sink = monitor(client: client)
    m.send(:dispatch_status, FakeIssue.new(15_894, 11_154), FakePipeline.new(215_229, status))
    [sink, client]
  end

  # --- the production case ------------------------------------------------

  def test_manual_with_green_blocking_jobs_is_treated_as_green
    jobs = [job(status: 'success', name: 'test'), job(status: 'success', name: 'rubocop_light'),
            job(status: 'manual', name: 'deploy_review'), job(status: 'manual', name: 'stop_review')]
    sink, = dispatch(jobs: jobs)

    assert_equal [15_894], sink[:green]
    assert_empty sink[:red]
  end

  def test_manual_with_a_failed_blocking_job_is_treated_as_red
    jobs = [job(status: 'success', name: 'rubocop_light'), job(status: 'failed', name: 'test'),
            job(status: 'manual', name: 'deploy_review')]
    sink, = dispatch(jobs: jobs)

    assert_empty sink[:green]
    assert_equal 1, sink[:red].size
    assert_equal 215_229, sink[:red].first.last.id, 'handle_red must receive the pipeline it triages'
  end

  # --- edge cases ---------------------------------------------------------

  # Consistent with dispatch_pipeline's "no pipeline found → treating as green".
  def test_manual_with_no_jobs_at_all_is_green
    sink, = dispatch(jobs: [])

    assert_equal [15_894], sink[:green]
  end

  def test_manual_with_only_manual_jobs_is_green
    sink, = dispatch(jobs: [job(status: 'manual', name: 'deploy_review')])

    assert_equal [15_894], sink[:green]
  end

  # GitLab itself says an allow_failure result does not gate the merge.
  def test_a_failed_allow_failure_job_does_not_make_it_red
    sink, = dispatch(jobs: [job(status: 'success'), job(status: 'failed', allow_failure: true, name: 'flaky')])

    assert_equal [15_894], sink[:green]
  end

  def test_an_allowed_failure_does_not_mask_a_real_one
    sink, = dispatch(jobs: [job(status: 'failed', allow_failure: true, name: 'flaky'),
                            job(status: 'failed', name: 'test')])

    assert_empty sink[:green]
    assert_equal 1, sink[:red].size
  end

  # A skipped pipeline is CI deciding nothing should run — the same absence of
  # verification dispatch_pipeline already treats as green when there is no
  # pipeline at all.
  def test_skipped_takes_the_same_path
    sink, = dispatch(jobs: [job(status: 'skipped')], status: 'skipped')

    assert_equal [15_894], sink[:green]
  end

  # --- what must NOT change ----------------------------------------------

  # An interrupted run has no verdict to read: its blocking jobs are `canceled`,
  # not `failed`, so the blocking-job rule would deliver a ticket whose tests
  # were killed mid-flight. Bounded generically by Autodev #53, not here.
  def test_canceled_still_waits_and_never_reads_the_jobs
    sink, client = dispatch(jobs: [job(status: 'canceled')], status: 'canceled')

    assert_empty sink[:green]
    assert_empty sink[:red]
    assert_equal 0, client.jobs_calls
  end

  # The one that must never regress: an API failure must not read as
  # "nothing failed → deliver".
  def test_an_unreachable_jobs_endpoint_delivers_nothing
    sink, = dispatch(client: StubClient.new(raise_error: true))

    assert_empty sink[:green]
    assert_empty sink[:red]
  end

  # --- the filter itself --------------------------------------------------

  def test_blocking_jobs_drops_allow_failure_and_unplayed_manual_jobs
    m, = monitor(client: StubClient.new)
    jobs = [job(status: 'success', name: 'test'), job(status: 'failed', allow_failure: true, name: 'flaky'),
            job(status: 'manual', name: 'deploy_review')]

    assert_equal(['test'], m.send(:blocking_jobs, jobs).map { |j| j['name'] })
  end

  # Fail safe: an absent allow_failure key reads as nil, which must count as
  # blocking rather than silently excusing the job.
  def test_a_job_without_an_allow_failure_key_is_blocking
    m, = monitor(client: StubClient.new)

    assert_equal 1, m.send(:blocking_jobs, [{ 'name' => 'test', 'status' => 'failed' }]).size
  end
end

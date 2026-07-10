# frozen_string_literal: true

require_relative '../../rails_helper'

# Autodev::DeployReview — availability probe + (re)trigger of the branch
# pipeline's `deploy_review` job. A fake GitLab client is injected so the
# tests never touch the network.
module Autodev
  class DeployReviewTest < ActiveSupport::TestCase # rubocop:disable Metrics/ClassLength
    Job = Struct.new(:id, :name, :status, :web_url)
    Pipeline = Struct.new(:id, :status, :web_url)

    # The gitlab gem returns a PaginatedResponse answering to #auto_paginate;
    # an Array subclass is enough for the service's needs.
    class FakeList < Array
      def auto_paginate
        self
      end
    end

    MergeRequest = Struct.new(:head_pipeline)

    class FakeClient
      attr_reader :calls

      def initialize(pipelines: [], jobs: [], raise_on: nil, head_pipeline: :unset)
        @pipelines = pipelines
        @jobs = jobs
        @raise_on = raise_on
        @head_pipeline = head_pipeline
        @calls = []
      end

      def merge_request(_project, _iid)
        @calls << [:merge_request]
        MergeRequest.new(@head_pipeline == :unset ? Pipeline.new(id: 9) : @head_pipeline)
      end

      def pipelines(_project, _opts = {})
        raise StandardError, 'boom' if @raise_on == :pipelines

        FakeList.new(@pipelines)
      end

      def pipeline_jobs(_project, _pid, _opts = {})
        FakeList.new(@jobs)
      end

      def job_play(project, job_id)
        @calls << [:play, project, job_id]
        Job.new(id: job_id, name: 'deploy_review', status: 'pending')
      end

      def job_retry(project, job_id)
        @calls << [:retry, project, job_id]
        Job.new(id: job_id + 1, name: 'deploy_review', status: 'pending')
      end
    end

    # Unique iid per call so a test that probes several statuses in a loop
    # doesn't trip the (project_path, issue_iid) unique index.
    def make_issue(branch: 'autodev/issue-1', mr_iid: nil)
      @iid_seq = (@iid_seq || 0) + 1
      Issue.create!(project_path: 'group/proj', issue_iid: @iid_seq, mr_iid: mr_iid,
                    status: 'checking_pipeline', branch_name: branch)
    end

    def deploy_job(status:)
      Job.new(id: 42, name: 'deploy_review', status: status, web_url: 'https://gl/j/42')
    end

    def availability_for(status)
      client = FakeClient.new(pipelines: [Pipeline.new(id: 9)], jobs: [deploy_job(status: status)])
      Autodev::DeployReview.new(make_issue, client: client).availability
    end

    def test_availability_manual_job_is_available_to_play
      outcome = availability_for('manual')

      assert_equal :available, outcome.state
      assert_equal :play, outcome.action
    end

    def test_availability_finished_job_is_available_to_retry
      %w[success failed canceled].each do |status|
        outcome = availability_for(status)

        assert_equal :available, outcome.state, "#{status} should be available"
        assert_equal :retry, outcome.action, "#{status} should retry"
      end
    end

    def test_availability_blocked_when_upstream_stage_not_done
      %w[created skipped].each do |status|
        assert_equal :blocked, availability_for(status).state, "#{status} should be blocked"
      end
    end

    def test_availability_running_when_deploy_in_flight
      %w[running pending preparing waiting_for_resource scheduled].each do |status|
        assert_equal :running, availability_for(status).state, "#{status} should be running"
      end
    end

    def test_availability_unknown_for_unrecognised_status
      assert_equal :unknown, availability_for('some_future_status').state
    end

    def test_uses_mr_head_pipeline_when_issue_has_mr
      client = FakeClient.new(head_pipeline: Pipeline.new(id: 77), jobs: [deploy_job(status: 'manual')])
      outcome = Autodev::DeployReview.new(make_issue(mr_iid: 12), client: client).availability

      assert_equal :available, outcome.state
      assert_includes client.calls, [:merge_request]
    end

    def test_no_pipeline_when_mr_has_no_head_pipeline
      client = FakeClient.new(head_pipeline: nil)
      outcome = Autodev::DeployReview.new(make_issue(mr_iid: 12), client: client).availability

      assert_equal :no_pipeline, outcome.state
    end

    def test_availability_no_branch_when_blank
      client = FakeClient.new(pipelines: [Pipeline.new(id: 9)], jobs: [deploy_job(status: 'manual')])

      assert_equal :no_branch, Autodev::DeployReview.new(make_issue(branch: ''), client: client).availability.state
    end

    def test_availability_no_pipeline_when_none
      assert_equal :no_pipeline, Autodev::DeployReview.new(make_issue, client: FakeClient.new).availability.state
    end

    def test_availability_no_job_when_absent
      client = FakeClient.new(pipelines: [Pipeline.new(id: 9)],
                              jobs: [Job.new(id: 1, name: 'test', status: 'success')])

      assert_equal :no_job, Autodev::DeployReview.new(make_issue, client: client).availability.state
    end

    def test_availability_error_on_gitlab_failure
      client = FakeClient.new(raise_on: :pipelines)

      assert_equal :error, Autodev::DeployReview.new(make_issue, client: client).availability.state
    end

    def test_trigger_plays_a_still_manual_job
      client = FakeClient.new(pipelines: [Pipeline.new(id: 9)], jobs: [deploy_job(status: 'manual')])
      outcome = Autodev::DeployReview.new(make_issue, client: client).trigger!

      assert_equal :triggered, outcome.state
      assert_equal :play, outcome.action
      assert_equal [[:play, 'group/proj', 42]], client.calls
    end

    def test_trigger_retries_an_already_run_job
      client = FakeClient.new(pipelines: [Pipeline.new(id: 9)], jobs: [deploy_job(status: 'success')])
      outcome = Autodev::DeployReview.new(make_issue, client: client).trigger!

      assert_equal :triggered, outcome.state
      assert_equal :retry, outcome.action
      assert_equal [[:retry, 'group/proj', 42]], client.calls
    end

    def test_trigger_picks_the_latest_job_instance
      client = FakeClient.new(
        pipelines: [Pipeline.new(id: 9)],
        jobs: [Job.new(id: 10, name: 'deploy_review', status: 'failed'),
               Job.new(id: 20, name: 'deploy_review', status: 'manual')]
      )
      Autodev::DeployReview.new(make_issue, client: client).trigger!

      assert_equal [[:play, 'group/proj', 20]], client.calls
    end

    def test_trigger_without_job_does_not_call_gitlab
      client = FakeClient.new(pipelines: [Pipeline.new(id: 9)], jobs: [])
      outcome = Autodev::DeployReview.new(make_issue, client: client).trigger!

      assert_equal :no_job, outcome.state
      assert_empty client.calls
    end

    def test_trigger_on_non_actionable_job_does_not_call_gitlab
      { 'skipped' => :blocked, 'running' => :running }.each do |status, state|
        client = FakeClient.new(pipelines: [Pipeline.new(id: 9)], jobs: [deploy_job(status: status)])
        outcome = Autodev::DeployReview.new(make_issue, client: client).trigger!

        assert_equal state, outcome.state, status
        assert_empty client.calls, status
      end
    end

    # Target (task #43): the service is agnostic to what `project_path` /
    # `branch_name` / `mr_iid` come from — a Target struct (no Issue row)
    # works exactly like an Issue for both availability and trigger.
    def test_availability_works_with_a_target_instead_of_an_issue
      client = FakeClient.new(head_pipeline: Pipeline.new(id: 77), jobs: [deploy_job(status: 'manual')])
      target = Autodev::DeployReview::Target.new(project_path: 'group/proj', branch_name: nil, mr_iid: 12)

      outcome = Autodev::DeployReview.new(target, client: client).availability

      assert_equal :available, outcome.state
      assert_equal :play, outcome.action
      assert_includes client.calls, [:merge_request]
    end

    def test_trigger_works_with_a_target_instead_of_an_issue
      client = FakeClient.new(pipelines: [Pipeline.new(id: 9)], jobs: [deploy_job(status: 'success')])
      target = Autodev::DeployReview::Target.new(project_path: 'group/proj', branch_name: 'some-branch', mr_iid: nil)

      outcome = Autodev::DeployReview.new(target, client: client).trigger!

      assert_equal :triggered, outcome.state
      assert_equal :retry, outcome.action
      assert_equal [[:retry, 'group/proj', 42]], client.calls
    end

    def test_target_with_no_branch_and_no_mr_is_no_branch
      target = Autodev::DeployReview::Target.new(project_path: 'group/proj', branch_name: nil, mr_iid: nil)

      assert_equal :no_branch, Autodev::DeployReview.new(target, client: FakeClient.new).availability.state
    end
  end
end

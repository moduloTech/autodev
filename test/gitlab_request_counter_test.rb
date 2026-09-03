# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/gitlab_request_counter'

# Autodev #96: GitlabRequestCounter wraps the client GitlabHelpers builds so
# every call — read or write — is counted without any of the twelve call
# sites of build_gitlab_client changing. See the design spec for the
# classification rule and why writes need their own counting (GitlabHelpers
# .answer only ever sees reads).
class GitlabRequestCounterTest < Minitest::Test
  include DatabaseTestHelper

  def setup
    setup_database
  end

  # A stand-in for the gitlab gem client: plain Ruby objects, no HTTP.
  class FakeClient
    attr_reader :calls

    def initialize
      @calls = []
    end

    def issue(project, iid)
      @calls << [:issue, project, iid]
      'the issue'
    end

    def create_issue_note(project, iid, body)
      @calls << [:create_issue_note, project, iid, body]
      'the note'
    end

    def job_retry(project, job_id)
      @calls << [:job_retry, project, job_id]
      'retried'
    end

    def flaky
      raise Net::OpenTimeout, 'timed out'
    end

    def buggy
      raise ArgumentError, 'not a transport failure'
    end
  end

  def counter(client = FakeClient.new)
    GitlabRequestCounter.new(client)
  end

  # --- classification -------------------------------------------------------

  def test_classify_recognises_every_write_method_this_codebase_calls
    writes = %w[create_issue create_issue_note create_merge_request create_merge_request_discussion
                create_merge_request_note edit_issue edit_issue_note job_play job_retry
                resolve_merge_request_discussion retry_pipeline upload_file]

    writes.each { |name| assert_equal :write, GitlabRequestCounter.classify(name), name }
  end

  def test_classify_defaults_to_read
    reads = %w[issue issues issue_notes merge_request merge_request_discussions pipeline_jobs project user
               something_nobody_calls_yet]

    reads.each { |name| assert_equal :read, GitlabRequestCounter.classify(name), name }
  end

  # --- delegation -------------------------------------------------------------

  def test_delegates_to_the_wrapped_client_and_returns_its_value
    assert_equal 'the issue', counter.issue('group/p', 42)
  end

  def test_forwards_all_arguments
    client = FakeClient.new
    counter(client).create_issue_note('group/p', 42, 'hello')

    assert_equal [[:create_issue_note, 'group/p', 42, 'hello']], client.calls
  end

  def test_a_method_the_client_does_not_respond_to_still_raises_no_method_error
    assert_raises(NoMethodError) { counter.this_does_not_exist }
  end

  # --- counting ---------------------------------------------------------------

  def test_a_read_call_increments_a_read_row
    counter.issue('group/p', 42)

    row = GitlabRequestStat.sole

    assert_equal 'read', row.kind
    assert_equal 'issue', row.endpoint
    assert_equal 1, row.count
  end

  def test_a_write_call_increments_a_write_row
    counter.create_issue_note('group/p', 42, 'hello')

    row = GitlabRequestStat.sole

    assert_equal 'write', row.kind
    assert_equal 'create_issue_note', row.endpoint
  end

  def test_an_irregular_write_method_is_still_counted_as_a_write
    counter.job_retry('group/p', 7)

    assert_equal 'write', GitlabRequestStat.sole.kind
  end

  def test_two_calls_to_the_same_endpoint_bump_the_same_row
    c = counter
    c.issue('group/p', 1)
    c.issue('group/p', 2)

    assert_equal 1, GitlabRequestStat.count
    assert_equal 2, GitlabRequestStat.sole.count
  end

  # --- failures -----------------------------------------------------------

  def test_a_transport_error_is_recorded_and_still_raised
    assert_raises(Net::OpenTimeout) { counter.flaky }

    row = GitlabTransportFailure.sole

    assert_equal %w[read flaky Net::OpenTimeout], [row.kind, row.endpoint, row.error_class]
  end

  def test_a_non_transport_error_is_not_recorded_as_a_transport_failure
    assert_raises(ArgumentError) { counter.buggy }

    assert_equal 0, GitlabTransportFailure.count
  end

  def test_a_transport_failure_still_counts_as_an_attempted_request
    assert_raises(Net::OpenTimeout) { counter.flaky }

    assert_equal 1, GitlabRequestStat.sole.count
  end
end

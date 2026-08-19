# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/port_allocator'
require 'autodev/danger_claude_runner'

# Every danger-claude call records liveness (Autodev #50).
#
# The dormant audit's active arm reads "no activity_events row for
# stuck_active_after" as "the worker died". Per-state business events do not
# bound that: PipelineFixer emits one event on entering fixing_pipeline, then
# makes two calls per failed job with nothing in between, so silence there is
# N × 2 × dc_timeout. Recording it per call — in the one place every call passes
# through — bounds it at one call regardless of the loop.
class DangerClaudeRunnerHeartbeatTest < Minitest::Test
  include DatabaseTestHelper

  # Proves the DB-only claim rather than assuming it: raises on any message,
  # so if ActivityLogger.heartbeat! (or anything else in the call path) ever
  # touched the GitLab client, the test would error instead of passing
  # regardless of whether it did.
  class RaisingClient
    def method_missing(name, *)
      raise "unexpected GitLab client call: #{name}"
    end

    def respond_to_missing?(*)
      true
    end
  end

  # Host for DangerClaudeRunner's two danger-claude entry points with the
  # subprocess stubbed: what is under test is the activity row the call writes,
  # not danger-claude itself.
  class Harness
    include DangerClaudeRunner

    attr_reader :timeout_calls

    def initialize(issue:, logger:, client: nil)
      init_runner(client: client, config: { 'dc_timeout' => 1800 },
                  project_config: { 'path' => 'group/project' },
                  logger: logger, token: 'tok')
      @dc_issue = issue
      @timeout_calls = []
    end

    # ProcessRunner#run_with_timeout stand-in. Returns the envelope
    # danger-claude emits under --output-format json, so capture_session_and_text
    # parses it instead of taking the parse-failed branch (which would write a
    # warn event of its own and muddy the assertions).
    #
    # `timeout:` accepted and ignored (Autodev #74 fix round 1): `danger_claude_prompt`
    # now always forwards its own `timeout:` kwarg (nil unless a caller overrides
    # it), mirroring the real `ProcessRunner#run_with_timeout` signature.
    def run_with_timeout(cmd, _args, chdir:, label: nil, timeout: nil)
      @timeout_calls << { cmd: cmd, chdir: chdir, label: label, timeout: timeout }
      ['{"result":"ok","session_id":"s1"}', '', true]
    end
  end

  def setup
    setup_database
    @issue = create_issue(status: 'implementing')
    @harness = Harness.new(issue: @issue, logger: StubLogger.new)
  end

  def heartbeats
    ActivityEvent.where(issue_id: @issue.id, kind: 'heartbeat').order(:id).to_a
  end

  def test_prompt_writes_one_heartbeat
    @harness.send(:danger_claude_prompt, '/tmp/wd', 'do the thing', label: '-p (implement code)')

    assert_equal 1, heartbeats.size
    assert_equal '-p (implement code)', heartbeats.first.payload['label']
  end

  def test_commit_writes_one_heartbeat
    @harness.send(:danger_claude_commit, '/tmp/wd', label: '-c (pipeline fix: rubocop)')

    assert_equal 1, heartbeats.size
    assert_equal '-c (pipeline fix: rubocop)', heartbeats.first.payload['label']
  end

  # The bound is per call, so a loop of N calls leaves N markers — this is what
  # keeps PipelineFixer's N-jobs loop under the window.
  def test_each_call_in_a_loop_leaves_its_own_marker
    3.times do |i|
      @harness.send(:danger_claude_prompt, '/tmp/wd', "fix job #{i}", label: "-p (job #{i})")
      @harness.send(:danger_claude_commit, '/tmp/wd', label: "-c (job #{i})")
    end

    assert_equal 6, heartbeats.size
  end

  # No GitLab round-trip: the client raises on any message, so the heartbeat
  # path must never touch it. If it did, this call would raise instead of
  # reaching the assertion. The activity note on the issue is deliberately
  # left alone.
  def test_no_gitlab_call_is_made
    harness = Harness.new(issue: @issue, logger: StubLogger.new, client: RaisingClient.new)

    harness.send(:danger_claude_prompt, '/tmp/wd', 'do the thing')

    assert_equal 1, heartbeats.size
  end

  def test_no_issue_tracked_is_a_no_op
    harness = Harness.new(issue: nil, logger: StubLogger.new)

    harness.send(:danger_claude_prompt, '/tmp/wd', 'do the thing')

    assert_empty ActivityEvent.where(kind: 'heartbeat')
  end
end

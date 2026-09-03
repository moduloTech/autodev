# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/pipeline_monitor'

# A secret must not be readable back from `issues.dc_stdout` / `issues.dc_stderr`
# (Autodev #59).
#
# `give_up_reviewing` scrubbed the message it logged and wrote the two columns
# raw — and there are thirteen other `dc_stdout:` / `dc_stderr:` writes in the
# product, none of which scrubbed either, two of them on success paths
# (`IssueProcessor#persist_finalize`, `QuestionHandler#finalize_question`). The
# guard therefore lives in `ProcessRunner#record_output`, the single writer of the
# two buffers, and this test asserts the property that matters through a real
# persistence site rather than the implementation of any one of them: what the
# capture path saw is on the row, minus the token.
#
# The columns are not a write-only audit trail — `IssueShow` renders them and the
# CLI `--errors` prints stderr — so a PAT landing here is a PAT on a dashboard.
class DcOutputPersistenceScrubTest < Minitest::Test
  include DatabaseTestHelper

  TOKEN = 'glpat-Abc123DEF456ghi789'
  PROJECT_CONFIG = { 'path' => 'group/project' }.freeze

  def setup
    setup_database
    @issue = build_reviewing_issue
    @monitor = build_monitor
    # `:unusable_output`, not `:tool_unavailable` (Autodev #107): this test is
    # about what `give_up_reviewing` writes to the row, which only
    # `:unusable_output` still reaches — `execute_mr_review`'s real outcomes no
    # longer spend the budget at all, but the stub only needs to drive the
    # give-up path, not replay the binary's actual vocabulary.
    @monitor.define_singleton_method(:execute_mr_review) { |_| :unusable_output }
    @issue.update(review_failure_count: PipelineMonitor::Reviewer::REVIEW_FAILURE_THRESHOLD - 1)
  end

  def test_a_bare_gitlab_token_does_not_survive_persistence
    give_up_with("Authorization: Bearer #{TOKEN}\n", '')

    assert_equal 'review_failures_exhausted', @issue.attention_reason
    refute_includes @issue.dc_stdout, TOKEN, 'the PAT must not be readable back from the row'
  end

  def test_credentials_embedded_in_a_url_do_not_survive_persistence
    give_up_with('', "remote: https://oauth2:#{TOKEN}@source.example.fr/g/p.git rejected\n")

    refute_includes @issue.dc_stderr, TOKEN, 'the PAT must not be readable back from the row'
    assert_includes @issue.dc_stderr, 'https://oauth2:***@source.example.fr/g/p.git'
  end

  # Scrubbing must not cost the diagnostic — recovering it is what #49 was for.
  # Both of these are verbatim shapes from production rows.
  def test_everything_that_is_not_a_secret_survives_verbatim
    give_up_with("unknown option -H\n", "Unexpected error: Token was revoked.\n")

    assert_includes @issue.dc_stdout, 'unknown option -H'
    assert_includes @issue.dc_stderr, 'Unexpected error: Token was revoked.'
  end

  private

  # Fills the two buffers the way a real run does — through
  # ProcessRunner#record_output, their only writer — then drives the give-up that
  # copies them onto the row.
  def give_up_with(out, err)
    @monitor.instance_variable_set(:@dc_stdout, +'')
    @monitor.instance_variable_set(:@dc_stderr, +'')
    @monitor.send(:record_output, 'mr-review', nil, Thread.new { out }, Thread.new { err })
    @monitor.send(:launch_review, @issue)
    @issue.reload
  end

  def build_reviewing_issue
    issue = create_issue(mr_iid: 1, mr_url: 'https://gitlab.example/group/project/-/merge_requests/1',
                         issue_author_id: 7, review_count: 0)
    advance_to(issue, 'checking_pipeline')
    issue._review_count_zero = true
    issue.pipeline_green!
    issue
  end

  def build_monitor
    monitor = PipelineMonitor.allocate
    monitor.instance_variable_set(:@project_path, 'group/project')
    monitor.instance_variable_set(:@project_config, PROJECT_CONFIG)
    monitor.instance_variable_set(:@logger, StubLogger.new)
    monitor.instance_variable_set(:@client, NoopClient.new)
    monitor.instance_variable_set(:@dc_issue, @issue)
    monitor
  end

  # Swallows the GitLab traffic the give-up path fans out to (label, reassign,
  # note upsert, notification). We assert on the persisted row, not on API calls.
  class NoopClient
    def method_missing(_name, *_args, **_kwargs)
      Struct.new(:id, :labels, :assignee, :assignees, :body).new(1, [], nil, [], 'body')
    end

    def respond_to_missing?(_name, _include_private = false)
      true
    end
  end
end

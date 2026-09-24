# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/activity_logger'

# Autodev #86 — every flag `ClarificationWatch` sets is about the wait, so the
# resume that ends the wait ends the flag too. Left on, a request back at work
# would keep reading "reassigned" or "unanswered" on the operator's board, and
# `dispatch_done_unassigned` excludes flagged rows, so its delivery would skip
# the `post_completion` hook.
#
# Both callers of `ClarificationResume#resume!` are covered: the live poll and
# the arrears sweep.
class AResumedRequestDropsItsClarificationFlagTest < Minitest::Test
  include DatabaseTestHelper

  PATH = 'group/project'
  AUTODEV_ID = 7
  REQUESTED_AT = Time.utc(2026, 9, 1, 10, 0, 0)

  FakeUser = Struct.new(:id)
  FakeIssue = Struct.new(:state, :assignees, :labels)
  FakeNote = Struct.new(:system, :created_at, :body)
  Paginated = Struct.new(:items) do
    def auto_paginate = items
  end

  # A ticket still ours, carrying one human answer after the question.
  class StubClient
    def user = FakeUser.new(AUTODEV_ID)
    def issue(_path, _iid) = FakeIssue.new('opened', [FakeUser.new(AUTODEV_ID)], ['To Do'])

    def issue_notes(_path, _iid, **)
      Paginated.new([FakeNote.new(false, '2026-09-02T10:00:00Z', 'Voici la précision demandée.')])
    end

    def create_issue_note(*) = Struct.new(:id).new(1)
    def issue_note(*) = Struct.new(:id, :body).new(1, '')
    def edit_issue_note(*) = nil
  end

  def setup
    setup_database
    @logger = StubLogger.new
    GitlabHelpers.instance_variable_set(:@current_user_id, AUTODEV_ID)
  end

  def flagged
    create_issue(project_path: PATH, status: 'needs_clarification', clarification_requested_at: REQUESTED_AT,
                 needs_attention: true, attention_reason: 'clarification_unanswered',
                 attention_detail: 'residue')
  end

  def assert_trio_cleared(issue)
    issue.reload

    assert_equal 'pending', issue.status
    refute issue.needs_attention
    assert_nil issue.attention_reason
    assert_nil issue.attention_detail
  end

  def test_resume_clears_the_attention_trio
    issue = flagged
    Autodev::ClarificationResume.new(client: StubClient.new, path: PATH, logger: @logger).resume!(issue)

    assert_trio_cleared(issue)
  end

  def test_the_sweep_clears_it_through_the_same_resume
    issue = flagged
    GitlabHelpers.stub(:build_gitlab_client, StubClient.new) do
      IssueProcessJob.stub(:perform_later, nil) do
        Autodev::ClarificationSweep.new(config: { 'gitlab_url' => 'x', 'gitlab_token' => 'x' },
                                        apply: true, out: StringIO.new).run
      end
    end

    assert_trio_cleared(issue)
  end
end

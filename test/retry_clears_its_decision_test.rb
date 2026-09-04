# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'

# Autodev #111. perform_retry_stuck clears next_retry_at as its first statement;
# perform_retry_errored cleared error_message and started_at and left the stamp.
# Observed on powerpanne/core#16030, 03/09/2026: next_retry_at = 03/09 18:30, in
# the past, on a row no longer in `error`.
#
# The rule: entering `error` writes the retry decision (mark_failed), leaving it
# erases it. PollDispatcher.retryable? reads the stamp and nothing else, so a
# residue is a decision nobody took.
class RetryClearsItsDecisionTest < Minitest::Test
  include DatabaseTestHelper

  CONFIG = { 'gitlab_token' => 'x', 'gitlab_url' => 'https://gitlab.example' }.freeze
  PROJECT_CONFIG = { 'path' => 'group/project' }.freeze

  def setup
    setup_database
  end

  def test_an_errored_retry_clears_the_stamp
    issue = errored_issue(mr_iid: 11_333)

    run_retry(issue, :retry_errored)

    assert_nil issue.reload.next_retry_at,
               'leaving error must erase the decision that scheduled the return'
  end

  def test_a_stuck_retry_clears_the_stamp
    issue = ::Issue.create!(project_path: 'group/project', issue_iid: 2, status: 'pending',
                            next_retry_at: 1.hour.ago, retry_count: 1)

    run_retry(issue, :retry_stuck)

    assert_nil issue.reload.next_retry_at
  end

  private

  def errored_issue(mr_iid:)
    ::Issue.create!(project_path: 'group/project', issue_iid: 1, status: 'error',
                    mr_iid: mr_iid, next_retry_at: 1.hour.ago, retry_count: 1,
                    error_message: 'boom')
  end

  # Runs the job's perform_retry_errored / perform_retry_stuck against real
  # ActiveRecord transitions, with the GitLab-touching collaborators stubbed to
  # no-ops — this test is about the stamp, not about the label, the activity
  # note, the handover check (Autodev #102, its own
  # test/errored_retry_respects_a_handover_test.rb), or IssueProcessor#process
  # (which perform_retry_stuck calls and which clones + runs danger-claude for
  # real).
  def run_retry(issue, action)
    job = IssueProcessJob.new
    job.define_singleton_method(:handed_over?) { |*| false }
    job.define_singleton_method(:restore_working_label) { |*| nil }
    job.define_singleton_method(:log_retry_activity) { |*| nil }

    fake_processor = Object.new.tap { |o| o.define_singleton_method(:process) { |*| nil } }
    ::IssueProcessor.stub(:new, fake_processor) do
      job.send(:"perform_#{action}", issue, CONFIG, PROJECT_CONFIG)
    end
  end
end

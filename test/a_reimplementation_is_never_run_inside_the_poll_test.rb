# frozen_string_literal: true

require_relative 'test_helper'

# A label resume that sends a finished request back to implementation used to
# run the whole implementation *inside the poll* (alpha-58 integration review):
# `PollRouter#enqueue_issue_processing` handed `IssueProcessor#process` to
# `PollDispatcher::NullPool`, whose `enqueue?` called the block in place. The
# poll job then held its thread for the clone, the danger-claude call and the
# push — measured on 15/10/2026, three `AutodevPollJob`s of 608 s, 918 s and
# 2134 s. With the poll alone on its one-thread queue (Autodev #139), that froze
# every poll behind one re-implementation, past `poll_stale_after`.
#
# The re-implementation is now an `IssueProcessJob :process` like every other
# piece of work: the reentry leaves the row in `pending`, which is exactly what
# `DISPATCHED_FROM[:process]` accepts (Autodev #140).
class AReimplementationIsNeverRunInsideThePollTest < Minitest::Test
  include DatabaseTestHelper

  PATH = 'group/project'
  FakeGlIssue = Struct.new(:iid, :title)

  def setup = setup_database

  def router
    PollRouter.allocate.tap do |r|
      { config: { 'gitlab_url' => 'https://gitlab.example' }, project_config: { 'path' => PATH }, logger: StubLogger.new, token: 'x', project_path: PATH }
        .each { |name, value| r.instance_variable_set(:"@#{name}", value) }
      r.define_singleton_method(:log_activity) { |*| nil }
    end
  end

  def reenter(issue)
    enqueued = []
    IssueProcessor.stub(:new, ->(**) { flunk 'the re-implementation ran inside the poll' }) do
      IssueProcessJob.stub(:perform_later, ->(*args) { enqueued << args }) do
        router.send(:reenter_via_reimplementation, FakeGlIssue.new(issue.issue_iid, 'a request'), issue)
      end
    end
    enqueued
  end

  def test_the_reentry_enqueues_a_process_job_instead_of_running_the_processor
    issue = create_issue(project_path: PATH, status: 'done')

    assert_equal [[PATH, issue.issue_iid, :process]], reenter(issue)
  end

  def test_the_enqueued_job_finds_the_row_in_a_state_it_accepts
    issue = create_issue(project_path: PATH, status: 'done')
    reenter(issue)

    assert_includes IssueProcessJob::DISPATCHED_FROM.fetch(:process), issue.reload.status
  end

  # Nothing else runs a processor from the poll: the router has no pool to hand
  # one to, and the dispatcher builds its routers without one.
  def test_the_router_takes_no_pool
    refute_includes PollRouter.instance_method(:initialize).parameters.map(&:last), :pool
    refute Autodev::PollDispatcher.const_defined?(:NullPool, false), 'NullPool came back'
  end
end

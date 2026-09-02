# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'autodev/mr_fixer'

# The wiring both classes need. `PATH` lives here too: a method defined in this
# module resolves constants against the module, not against whichever class
# included it.
module StopFixtures
  PATH = 'group/project'

  def configure(fix)
    fix.instance_variable_set(:@project_config, { 'path' => PATH })
    fix.instance_variable_set(:@config, {})
    fix.instance_variable_set(:@project_path, PATH)
    fix.instance_variable_set(:@dc_stdout, '')
    fix.instance_variable_set(:@dc_stderr, '')
  end

  # `notify_localized` is the one that would reach the client's ticket, so it is
  # captured rather than silenced.
  def silence(fix, notes)
    %i[log log_error].each { |noop| fix.define_singleton_method(noop) { |*| nil } }
    fix.define_singleton_method(:log_activity) { |*, **| nil }
    fix.define_singleton_method(:notify_localized) { |_iid, key, **| notes << key }
  end

  class NullLogger
    %i[info warn error debug].each { |l| define_method(l) { |*, **| nil } }
  end
end

# Autodev #97 — a stop decided by a human must hold against work already in
# flight.
#
# Observed in production on 01/09/2026. A request was in `reviewing`. It was
# closed from the dashboard — `reviewing` → `closed`, verified in the database.
# Eight minutes later a `reviewing` → `checking_pipeline` transition arrived,
# written by the danger-claude call that was still running and finished after the
# close. It had been decided on the in-memory copy of the row, which still said
# `reviewing`, and `save!` wrote every dirty attribute over the top. The request
# resumed as if nothing had happened: green pipeline, seventeen discussions,
# twenty more minutes of work.
#
# A lost update, and the shape of Autodev #61 moved from the entry of a job to
# its exit. #61 guards the *dispatch*: a job is dropped when the row no longer
# holds the status its pass selected on. It says nothing about the end of a job,
# and a danger-claude call runs ten to sixty minutes — long enough for the row to
# change hands several times.
#
# ## Why the guard is in `persist_status_change!` and nowhere else
#
# That callback is the one save every AASM transition goes through, so the rule
# is written once and covers the review, the discussion fix, the pipeline fix and
# anything added later. Guarding each long-running exit instead would be a list
# somebody has to keep complete — and the reason this defect exists is that
# nobody thought to write the first entry of that list.
#
# It also covers the three human gestures without naming any of them: the
# dashboard's close and forced transition go through AASM, `reset` goes through
# `Issue.reset_for_retry!`'s `update_all`, and the startup recoveries
# (`revive_stalled!`, `recover_on_startup!`) write `status` the same way. What
# the guard compares is the database against `aasm.from_state`; how the database
# got there is not its business.
class ACloseMustHoldTest < Minitest::Test
  include DatabaseTestHelper
  include StopFixtures

  def setup
    setup_database
  end

  def reviewing_issue
    create_issue(project_path: PATH, issue_iid: 700, mr_iid: 800, status: 'reviewing',
                 branch_name: 'autodev/700', issue_author_id: 42, review_count: 0)
  end

  # Somebody else moves the row while this object holds its old state — the
  # dashboard close, a forced transition, a reset, a startup recovery. All of
  # them end here.
  def move_row_to(issue, status)
    Issue.where(id: issue.id).update_all(status: status)
  end

  # The defect, at its smallest.
  def test_a_transition_decided_on_a_state_the_database_no_longer_holds_is_refused
    issue = reviewing_issue
    move_row_to(issue, 'closed')

    assert_raises(StaleTransitionError) { issue.review_done! }
  end

  # And the point of refusing: the human's gesture is what survives.
  def test_the_row_keeps_the_state_the_human_left_it_in
    issue = reviewing_issue
    move_row_to(issue, 'closed')

    begin
      issue.review_done!
    rescue StaleTransitionError
      nil
    end

    assert_equal 'closed', Issue.find(issue.id).status
  end

  # Nothing downstream of the save runs either — the activity row and the audit
  # log are written by callbacks that sit *after* it, so a refused transition
  # leaves no trace claiming it happened.
  def test_a_refused_transition_writes_no_activity_row
    issue = reviewing_issue
    move_row_to(issue, 'closed')
    before = ActivityEvent.where(issue_id: issue.id).count

    begin
      issue.review_done!
    rescue StaleTransitionError
      nil
    end

    assert_equal before, ActivityEvent.where(issue_id: issue.id).count
  end

  # A row somebody deleted is not a row this object may write back.
  def test_a_transition_on_a_row_that_no_longer_exists_is_refused
    issue = reviewing_issue
    Issue.where(id: issue.id).delete_all

    assert_raises(StaleTransitionError) { issue.review_done! }
  end

  # The control, and the one that matters most: the guard must not cost anything
  # to a row nobody touched. Every transition in the product goes through it.
  def test_a_transition_on_a_row_nobody_touched_is_written
    issue = reviewing_issue

    issue.review_done!

    assert_equal 'checking_pipeline', Issue.find(issue.id).status
  end

  # And two transitions in a row on the same object still work: the second reads
  # what the first wrote, which is the ordinary shape of a poll. Both are chosen
  # unguarded on purpose — `pipeline_green`'s branches are decided by instance
  # flags the caller sets, and this test is about the database, not about them.
  def test_two_transitions_on_the_same_object_still_chain
    issue = reviewing_issue

    issue.review_done!
    issue.mr_closed!

    assert_equal 'done', Issue.find(issue.id).status
  end

  # The boundary that writes the most: `MrFixer` answers an unexpected error by
  # marking the row failed, storing the message and posting a GitLab comment. On
  # a row a human has just closed, that comment is the second thing autodev says
  # about a ticket it was told to leave alone.
  def test_a_fix_round_that_ends_after_a_close_posts_nothing
    issue = create_issue(project_path: PATH, issue_iid: 701, mr_iid: 801,
                         status: 'fixing_discussions', branch_name: 'autodev/701',
                         issue_author_id: 42, review_count: 1)
    notes = []
    fixer = fixer_finishing_after_close(issue, notes)

    fixer.send(:execute_fix_cycle, issue, [{ id: 'a', title: 'A', notes: [] }])

    assert_equal 'closed', Issue.find(issue.id).status
    assert_empty notes
  end

  private

  # A round whose work completes normally, on a row somebody closed while it ran.
  # `new_commits?` false is the cheapest completed round; the transition it fires
  # at the end is the one the close has to survive.
  def fixer_finishing_after_close(issue, notes)
    MrFixer.allocate.tap do |fix|
      configure(fix)
      silence(fix, notes)
      stub_cycle_steps(fix, issue)
    end
  end

  def stub_cycle_steps(fix, issue)
    fix.define_singleton_method(:clone_and_checkout) { |*| nil }
    fix.define_singleton_method(:target_branch_for) { |*| 'master' }
    fix.define_singleton_method(:rebase_branch_on_target) { |*, **| nil }
    fix.define_singleton_method(:prepare_fix_environment) { |*| {} }
    fix.define_singleton_method(:new_commits?) { |*| false }
    # The close lands while the round is working, which is the whole point.
    fix.define_singleton_method(:fix_each_discussion) do |*|
      Issue.where(id: issue.id).update_all(status: 'closed')
      []
    end
  end
end

# Autodev #97, review of the alpha-52 lot — the same rule, at the seams the
# original pass did not cover.
#
# `refuse_stale_transition!` raises wherever a transition is decided on a stale
# copy of the row. #97 wired the boundary that catches it into the three workers
# and nowhere else, which leaves the refusal escaping at four places that reach a
# transition by another road. Each test below is one of them.
class AStopMustHoldAtEverySeamTest < Minitest::Test
  include DatabaseTestHelper
  include StopFixtures

  # `route`'s clause is exercised through a one-line probe rather than the whole
  # router: what is under test is that the boundary answers `:next` instead of
  # letting the refusal reach the pass.
  REENTRY_PROBE = lambda do |issue|
    Issue.where(id: issue.id).update_all(status: 'closed')
    issue.reenter!
    :routed
  rescue StaleTransitionError => e
    stop_on_stale_transition(e)
    :next
  end

  def setup = setup_database

  # Two transitions live outside `execute_fix_cycle`, so #97's rescue — which sits
  # in `MrFixer::ErrorHandler#handle_fix_error` — never sees them. `MrFixer#fix`
  # declares no `rescue StandardError`, so the refusal escapes to ActiveJob and the
  # job lands in Solid Queue's failed executions: a human needed, for the one thing
  # `fix`'s own comment says its clauses exist to avoid.
  #
  # The seam is `fix` itself. This is the round that finds no unresolved thread —
  # `transition_no_discussions` — reached with the row closed underneath it.
  def test_a_round_with_no_discussion_left_does_not_escape_when_the_row_moved
    issue = create_issue(project_path: PATH, issue_iid: 702, mr_iid: 802,
                         status: 'fixing_discussions', branch_name: 'autodev/702',
                         issue_author_id: 42, review_count: 1)
    fix = fixer_finding_nothing(issue)

    DiscussionSnapshot.stub(:capture, nil) { fix.fix(issue) }

    assert_equal 'closed', Issue.find(issue.id).status
  end

  # And the ceiling's give-up, which the same seam covers: `bail_on_fix_rounds`
  # fires `abandon` from `run_fix_round`, above `execute_fix_cycle`.
  def test_the_round_ceiling_does_not_escape_when_the_row_moved
    issue = create_issue(project_path: PATH, issue_iid: 703, mr_iid: 803,
                         status: 'fixing_discussions', branch_name: 'autodev/703',
                         issue_author_id: 42, review_count: 1,
                         discussion_fix_round: 99)
    fix = fixer_finding_nothing(issue)
    Issue.where(id: issue.id).update_all(status: 'closed')

    DiscussionSnapshot.stub(:capture, nil) { fix.fix(issue) }

    assert_equal 'closed', Issue.find(issue.id).status
  end

  # The poll passes transition rows in line, outside any worker, and #97 wired the
  # bound into the three **workers** only. `check_external_state` rescues
  # `Gitlab::Error::ResponseError` alone, so a refusal there escapes to
  # `PollDispatcher#dispatch`'s `rescue StandardError`, which logs and returns —
  # taking the six passes that had not run yet down with it, for the whole project,
  # that cycle. The remedy of #97 is right; what was missing is that it be local to
  # the row, as it is in the workers.
  def test_a_handover_stop_on_a_moved_row_does_not_take_the_cycle_down
    issue = create_issue(project_path: PATH, issue_iid: 704, mr_iid: 804,
                         status: 'reviewing', branch_name: 'autodev/704', issue_author_id: 42)
    dispatcher = dispatcher_seeing_a_handover(issue)

    dispatcher.send(:check_external_state, issue)

    assert_equal 'closed', Issue.find(issue.id).status
  end

  # `PollRouter#route` has the same shape with `ApiUnavailableError` alone, and its
  # own comment already carries the reason: the boundary is per issue so one row
  # does not take the project's cycle down.
  def test_a_reentry_on_a_moved_row_does_not_take_the_cycle_down
    issue = create_issue(project_path: PATH, issue_iid: 705, mr_iid: 805,
                         status: 'done', branch_name: 'autodev/705', issue_author_id: 42,
                         finished_at: Time.current)

    assert_equal :next, router_reentering.send(:handle_stale_reentry_probe, issue)
  end

  private

  def fixer_finding_nothing(issue)
    MrFixer.allocate.tap do |fix|
      configure(fix)
      silence(fix, [])
      fix.define_singleton_method(:fetch_unresolved_discussions) do |*|
        Issue.where(id: issue.id).update_all(status: 'closed')
        []
      end
    end
  end

  # A dispatcher whose ticket has had its workflow label moved on, against a row
  # the database has already closed.
  def dispatcher_seeing_a_handover(issue)
    Issue.where(id: issue.id).update_all(status: 'closed')
    Autodev::PollDispatcher.allocate.tap do |d|
      d.instance_variable_set(:@path, PATH)
      d.instance_variable_set(:@project_config, { 'path' => PATH })
      d.instance_variable_set(:@logger, NullLogger.new)
      d.instance_variable_set(:@client, labelless_client)
      stub_handover_reads(d)
    end
  end

  def stub_handover_reads(dispatcher)
    dispatcher.define_singleton_method(:externally_closed?) { |_| false }
    dispatcher.define_singleton_method(:assigned_to_autodev?) { |_| true }
    dispatcher.define_singleton_method(:stop_on_handover) { |i, _| i.close! }
  end

  def labelless_client
    Struct.new(:x).new(nil).tap do |c|
      c.define_singleton_method(:issue) { |_p, _i| Struct.new(:labels).new([]) }
    end
  end

  def router_reentering
    PollRouter.allocate.tap do |r|
      r.instance_variable_set(:@project_path, PATH)
      r.instance_variable_set(:@logger, NullLogger.new)
      r.define_singleton_method(:handle_stale_reentry_probe, &REENTRY_PROBE)
    end
  end
end

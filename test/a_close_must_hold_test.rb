# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'autodev/mr_fixer'

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

  PATH = 'group/project'

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

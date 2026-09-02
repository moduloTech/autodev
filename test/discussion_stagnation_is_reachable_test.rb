# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'autodev/mr_fixer'

# Autodev #99 — the guard that ends a non-converging fix loop was only reachable
# from the rounds that converged.
#
# `run_fix_cycle` ends two ways:
#
#     return finalize_no_commits(issue) unless new_commits?(work_dir, branch)
#     push_fixes(work_dir, branch)
#     finalize_success(issue, discussions, resolved)
#
# and `discussion_stagnated?` — which both counts the occurrence AND takes the
# decision — lived only in the second. So a round that produced no commit, which
# is exactly what a stagnation looks like from the inside, returned before the
# guard and neither counted nor checked.
#
# Measured on powerpanne 15205, 02/09/2026: eighteen rounds over sixteen hours,
# every discussion answering `discussion_unchanged`, the Claude quota exhausted
# twice in twelve hours — and `stagnation_signatures` reading `count: 1` at round
# 17. The guard existed, was configured (threshold 5), was tested, and had
# counted once.
#
# The pipeline twin never had the defect, and the shape it has is the one this
# file pins for the discussions side:
#
#     return if bail_on_stagnation?(...)   # every cycle, before the attempt
#     clone_and_fix(...)
#     count_fix_attempt(...)               # only a completed attempt counts
#
# i.e. the *check* is unconditional and the *count* is what Autodev #71 gated on
# a completed attempt. The discussions side had moved both, and the comment in
# `FailureHandler#check_stagnation_and_fix` cites it as its own precedent —
# "that is also the ordering the discussions side has always had" — which was
# true of the counting and false of the checking.
# ClassLength: one class for one defect, with the fixtures its two halves share —
# the guard's reachability and the ceiling behind it. The shape
# `ReviewArrearsSweepTest` already has, and splitting them would put the stubbed
# `MrFixer` in two places.
class DiscussionStagnationIsReachableTest < Minitest::Test # rubocop:disable Metrics/ClassLength
  include DatabaseTestHelper

  THRESHOLD = 3
  AUTHOR_ID = 42
  PATH = 'group/project'

  PROJECT_CONFIG = { 'path' => PATH, 'labels_todo' => ['To do'],
                     'label_doing' => 'Development::Doing',
                     'label_done' => 'Development::Awaiting Feature Review',
                     'label_attention' => 'Development::StandBy',
                     'stagnation_threshold' => THRESHOLD }.freeze

  # The same two threads every round: the signature is stable, so the counter has
  # nothing to blame for not advancing.
  DISCUSSIONS = [{ id: 'thread-a', title: 'A', notes: [] },
                 { id: 'thread-b', title: 'B', notes: [] }].freeze

  # The handback is asserted through the CLIENT rather than through the method
  # that performs it: Autodev #98 renames `reassign_to_author` to
  # `hand_ticket_back` on its own branch, and a test that stubs the name would
  # pass on one and error on the other for a reason that has nothing to do with
  # what it measures.
  class FakeClient
    attr_reader :assignments

    def initialize = @assignments = []

    def edit_issue(_path, iid, **opts)
      @assignments << [iid, opts[:assignee_ids]] if opts.key?(:assignee_ids)
      nil
    end
  end

  def setup
    setup_database
    @sink = { activity: [], notify: [], labels: [] }
    @client = FakeClient.new
  end

  # Everything `run_fix_cycle` does before its two terminal branches is stubbed:
  # this file is about which branch reaches the guard, not about cloning.
  # `new_commits?` is the switch — false is the round that changed nothing.
  def fixer(commits: false)
    MrFixer.allocate.tap do |fix|
      configure(fix)
      stub_side_effects(fix)
      stub_cycle_steps(fix, commits)
    end
  end

  def configure(fix)
    fix.instance_variable_set(:@client, @client)
    fix.instance_variable_set(:@project_config, PROJECT_CONFIG)
    fix.instance_variable_set(:@config, {})
    fix.instance_variable_set(:@project_path, PATH)
    fix.instance_variable_set(:@dc_stdout, '')
    fix.instance_variable_set(:@dc_stderr, '')
  end

  # The give-up's own writes, captured rather than performed — except the
  # handback, which goes through the client on purpose (see `FakeClient`).
  def stub_side_effects(fix)
    sink = @sink
    %i[log log_error].each { |noop| fix.define_singleton_method(noop) { |*| nil } }
    fix.define_singleton_method(:log_activity) { |_i, key, **vars| sink[:activity] << [key, vars] }
    fix.define_singleton_method(:notify_localized) { |_iid, key, **vars| sink[:notify] << [key, vars] }
    fix.define_singleton_method(:apply_label_attention) { |iid| sink[:labels] << iid }
  end

  def stub_cycle_steps(fix, commits)
    fix.define_singleton_method(:clone_and_checkout) { |*| nil }
    fix.define_singleton_method(:target_branch_for) { |*| 'master' }
    fix.define_singleton_method(:rebase_branch_on_target) { |*, **| nil }
    fix.define_singleton_method(:prepare_fix_environment) { |*| {} }
    fix.define_singleton_method(:fix_each_discussion) { |*| [] }
    fix.define_singleton_method(:new_commits?) { |*| commits }
    fix.define_singleton_method(:push_fixes) { |*| nil }
    fix.define_singleton_method(:fetch_unresolved_discussions) { |*| [] }
  end

  def issue_in_fixing(overrides = {})
    create_issue({ project_path: PATH, issue_iid: 700, mr_iid: 800, status: 'fixing_discussions',
                   branch_name: 'autodev/700', issue_author_id: AUTHOR_ID,
                   review_count: 1, fix_round: 0 }.merge(overrides))
  end

  def run_round(fix, issue)
    fix.send(:run_fix_cycle, issue, DISCUSSIONS, '/tmp/autodev_test')
  end

  # `dispatch_discussions` re-enqueues the row after the pipeline goes green
  # again; the loop this file measures is that cycle repeated.
  def next_round(issue)
    issue.update(status: 'fixing_discussions')
  end

  def signature_count(issue)
    JSON.parse(issue.reload.stagnation_signatures || '{}').dig('discussions', 'count')
  end

  # The defect itself, at its smallest: one round, no commit, and the occurrence
  # has to be recorded. Before the fix this answered nil — nothing written at all.
  def test_a_round_that_produces_no_commit_counts_towards_stagnation
    issue = issue_in_fixing

    run_round(fixer, issue)

    assert_equal 1, signature_count(issue)
  end

  # And the consequence: the give-up is reachable from the rounds that are the
  # reason it exists. `fixing_discussions` → `done` through the `abandon` event,
  # so the transition row, the attention flag, the end label and the handback all
  # happen — the shape Autodev #60 unified.
  def test_identical_rounds_that_change_nothing_reach_the_give_up
    issue = issue_in_fixing

    THRESHOLD.times do
      next_round(issue)
      run_round(fixer, issue)
    end

    assert_equal 'done', issue.reload.status
    assert_equal 'stagnation_discussions', issue.attention_reason
    assert issue.needs_attention
  end

  # The other half of the same give-up, split off so each test carries one claim:
  # the ticket goes back to a human. Without it the row is `done` on autodev and
  # nobody sees it — the disagreement Autodev #60 unified.
  def test_the_give_up_hands_the_ticket_back
    issue = issue_in_fixing

    THRESHOLD.times do
      next_round(issue)
      run_round(fixer, issue)
    end

    assert_equal [[700, [AUTHOR_ID]]], @client.assignments
  end

  # The control Autodev #71 asks for, in the other direction: a round that DID
  # push must keep counting too, or moving the check would have disarmed the
  # guard for the converging case instead.
  def test_a_round_that_pushed_still_counts_towards_stagnation
    issue = issue_in_fixing

    run_round(fixer(commits: true), issue)

    assert_equal 1, signature_count(issue)
  end

  # The ceiling, and the reason it is not a second guard of the same kind: it
  # reads one integer off the row. A signature that changes every round — which
  # is what the #99 investigation first suspected, and what any future change to
  # the thread set would produce — leaves the counter at 1 for ever, and the
  # ceiling is what still ends the loop.
  def test_the_ceiling_ends_a_loop_whose_signature_never_repeats
    issue = issue_in_fixing(fix_round: THRESHOLD * 3)
    fix = fixer

    fix.send(:run_fix_round, issue)

    assert_equal 'done', issue.reload.status
    assert_equal 'fix_rounds_exhausted', issue.attention_reason
  end

  # It is a ceiling, not a threshold: one round below it the work carries on.
  def test_a_round_below_the_ceiling_is_not_stopped
    issue = issue_in_fixing(fix_round: (THRESHOLD * 3) - 1)
    fix = fixer

    fix.send(:run_fix_round, issue)

    refute_equal 'fix_rounds_exhausted', issue.reload.attention_reason
  end

  # And it costs nothing to check: no GitLab read, no clone, no model call. The
  # thread list is fetched *after* it, so a row past the ceiling spends nothing.
  def test_the_ceiling_is_checked_before_any_gitlab_read
    issue = issue_in_fixing(fix_round: THRESHOLD * 3)
    fix = fixer
    read = []
    fix.define_singleton_method(:fetch_unresolved_discussions) { |*| read << :called and [] }

    fix.send(:run_fix_round, issue)

    assert_empty read
  end
end

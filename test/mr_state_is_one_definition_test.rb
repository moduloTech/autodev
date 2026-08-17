# frozen_string_literal: true

require_relative 'test_helper'
require_relative 'database_test_helper'
require 'autodev/gitlab_helpers'
require 'autodev/activity_logger'
require 'autodev/pipeline_monitor'
require 'autodev/poll_router'

# Autodev #72 — "does this merge request state carry a verdict" has one
# definition, and four readers.
#
# Autodev #69 put the allow-list in one place on purpose, so that widening the
# door would be a decision rather than an accident. Autodev #67, merged after it,
# wrote `when 'locked' then :wait` by hand in
# `PollRouter::ResumeHandler#reenter_destination` — a second copy, free to
# diverge from the first, which is the exact shape #62 removed for
# `fetch_unresolved_discussions`. Two more readers agreed with neither copy:
#
#   * `InfraRecheck#mr_open?` tested `== 'opened'`, so a `locked` MR read as "not
#     open" and **spent one of the `infra_recheck_max` attempts** on an answer
#     that meant "wait". The comment three lines above says a cycle that could
#     not read anything must not burn one.
#   * `PollDispatcher#mr_closed_or_merged?` tested `%w[merged closed]`, so a
#     `locked` MR counted as neither closed nor merged — the opposite of the
#     pipeline watch's sort — and let the `post_completion` hook through while
#     GitLab was performing the merge. Latent: no project configures
#     `post_completion` today.
#
# What is shared is the answer to "is `locked` a verdict", **not** the decision
# that follows it: the four readers ask different questions (was this delivered,
# does this need reimplementing, does this need re-arming, does this need
# deploying) and each keeps its own answer. So this file has two halves: the four
# readers all consult `MrState.transient?` — proved by widening that one
# predicate and watching all four change behaviour — and each of them still takes
# its own decision, on `locked` and on the states that do carry a verdict.

# A state nobody has to invent a meaning for: it is transient here only because
# the single definition was stubbed to say so. If a reader has its own copy of
# the list, it will not see this.
FUTURE_TRANSIENT_STATE = 'preparing'

module MrStateFixtures
  FakeMr = Struct.new(:state, :head_pipeline)
  FakePipeline = Struct.new(:id, :status)

  # Runs `block` in a world where the one definition also calls
  # FUTURE_TRANSIENT_STATE transient.
  def with_widened_list(&)
    widened = ->(state) { (MrState::TRANSIENT_STATES + [FUTURE_TRANSIENT_STATE]).include?(state.to_s) }
    MrState.stub(:transient?, widened, &)
  end
end

# --- 0. the home of the list ----------------------------------------------

class MrStateDefinitionTest < Minitest::Test
  # Moved out of `PipelineMonitor::MrStateChecker` by Autodev #72. It was a
  # module of the pipeline monitor, and three of the four readers are not the
  # pipeline monitor — one of them (`PollDispatcher`) is not even in `lib/`.
  def test_only_gitlabs_transitional_state_is_treated_as_a_wait
    assert_equal %w[locked], MrState::TRANSIENT_STATES
  end

  def test_the_predicate_reads_the_list
    states = ['locked', 'opened', 'merged', 'closed', FUTURE_TRANSIENT_STATE]

    assert_equal([true, false, false, false, false], states.map { |state| MrState.transient?(state) })
  end

  # `GitlabHelpers.field` can hand back a symbol or a nil; neither is a verdict
  # carrier and neither may raise.
  def test_the_predicate_takes_whatever_gitlab_returned
    assert_equal([true, false], [:locked, nil].map { |state| MrState.transient?(state) })
  end
end

# --- 1. the pipeline watch (PipelineMonitor::MrStateChecker) ---------------

class MrStateInThePipelineWatchTest < Minitest::Test
  include MrStateFixtures

  def concluded?(state)
    PipelineMonitor.allocate.send(:mr_state_concluded?, state)
  end

  def test_a_locked_mr_concludes_nothing
    refute concluded?('locked')
  end

  def test_a_state_added_to_the_one_list_concludes_nothing_here_too
    with_widened_list { refute concluded?(FUTURE_TRANSIENT_STATE) }
  end

  # The decision this reader takes is its own: `opened` keeps the watch, and
  # everything else — including a state GitLab has not invented yet — is an
  # outcome to sort (Autodev #66).
  def test_the_states_that_carry_a_verdict_still_do
    states = %w[merged closed something_gitlab_added_later opened]

    assert_equal([true, true, true, false], states.map { |state| concluded?(state) })
  end
end

# --- 2. the reentry decision (PollRouter::ResumeHandler) -------------------

class MrStateInTheReentryDecisionTest < Minitest::Test
  include MrStateFixtures

  ExistingIssue = Struct.new(:mr_iid, :issue_iid, :finished_at)

  class StubClient
    def initialize(state) = @state = state
    def merge_request(_path, _iid) = MrStateFixtures::FakeMr.new(@state, nil)
    def issue_notes(_path, _iid, **_opts) = Struct.new(:auto_paginate).new([])
  end

  def destination(state)
    router = PollRouter.allocate
    router.instance_variable_set(:@route_client, StubClient.new(state))
    router.instance_variable_set(:@project_path, 'group/project')
    router.send(:reenter_destination, ExistingIssue.new(7, 11_859, Time.now))
  end

  def test_a_locked_mr_waits
    assert_equal :wait, destination('locked')
  end

  # The duplication this ticket removes: `when 'locked' then :wait` was spelled
  # out here, so widening the one list did not reach this reader.
  def test_a_state_added_to_the_one_list_waits_here_too
    with_widened_list { assert_equal :wait, destination(FUTURE_TRANSIENT_STATE) }
  end

  # This reader's own decision, unchanged: a merged MR is shipped, an unknown
  # state gets the full reimplementation.
  def test_the_states_that_carry_a_verdict_still_route_where_they_did
    states = %w[merged closed something_gitlab_added_later opened]

    assert_equal(%i[skip_merged reimplementation reimplementation pipeline_check],
                 states.map { |state| destination(state) })
  end
end

# --- 3. the infra recheck (PipelineMonitor::InfraRecheck) ------------------

class MrStateInTheInfraRecheckTest < Minitest::Test
  include MrStateFixtures

  class FakeIssue
    attr_reader :issue_iid, :mr_iid

    def initialize
      @issue_iid = 16_081
      @mr_iid = 42
      @attrs = { infra_recheck_count: 0 }
    end

    def update(hash) = (@attrs.merge!(hash) and self)
    def infra_recheck_count = @attrs[:infra_recheck_count]
    def infra_recheck_at = @attrs[:infra_recheck_at]
  end

  class StubClient
    def initialize(state, status: 'success')
      @mr = MrStateFixtures::FakeMr.new(state, MrStateFixtures::FakePipeline.new(9, status))
    end

    def merge_request(_path, _iid) = @mr
    def pipeline_jobs(_path, _pid, **_opts) = []
  end

  def recheck(state, status: 'success')
    mon = PipelineMonitor.allocate
    mon.instance_variable_set(:@client, StubClient.new(state, status: status))
    mon.instance_variable_set(:@project_path, 'group/project')
    mon.instance_variable_set(:@project_config, {})
    mon.instance_variable_set(:@config, {})
    %i[log log_error].each { |noop| mon.define_singleton_method(noop) { |*| nil } }
    issue = FakeIssue.new
    [mon.recheck_infra_recovery(issue), issue]
  end

  # The bug: `== 'opened'` read a mid-merge MR as "not open", and every
  # non-recovery outcome spends one of the bounded attempts.
  def test_a_locked_mr_does_not_burn_a_recheck_attempt
    reentered, issue = recheck('locked')

    refute reentered, 'nothing was concluded, so the row must not be re-armed'
    assert_equal 0, issue.infra_recheck_count,
                 'a cycle that read "wait" spent one of the infra_recheck_max attempts'
    assert_nil issue.infra_recheck_at
  end

  def test_a_state_added_to_the_one_list_burns_nothing_here_either
    with_widened_list do
      _reentered, issue = recheck(FUTURE_TRANSIENT_STATE)

      assert_equal 0, issue.infra_recheck_count
    end
  end

  # This reader's own decision, unchanged: a closed MR is a verdict and the
  # attempt is spent on it, and a recovered open MR still re-arms the row.
  def test_a_closed_mr_still_spends_an_attempt
    _reentered, issue = recheck('closed')

    assert_equal 1, issue.infra_recheck_count
  end

  def test_a_recovered_open_mr_still_rearms_the_row
    reentered, issue = recheck('opened')

    assert reentered
    assert_equal 0, issue.infra_recheck_count
  end
end

# --- 4. the post-completion hook (PollDispatcher) --------------------------

class MrStateInThePostCompletionHookTest < Minitest::Test
  include DatabaseTestHelper
  include MrStateFixtures

  PROJECT_CONFIG = { 'path' => 'group/project', 'post_completion' => [%w[bin/deploy]],
                     'labels_todo' => ['To Do'], 'label_doing' => 'Development::Doing',
                     'label_done' => 'Development::Awaiting Feature Review' }.freeze
  AUTODEV_ID = 7
  HUMAN_ID = 999

  FakeUser = Struct.new(:id)
  FakeGlIssue = Struct.new(:state, :assignees, :labels)

  class StubClient
    def initialize(state) = @state = state
    def user = MrStateInThePostCompletionHookTest::FakeUser.new(AUTODEV_ID)

    # Unassigned from autodev: the condition the hook waits for.
    def issue(_path, _iid)
      MrStateInThePostCompletionHookTest::FakeGlIssue.new(
        'opened', [MrStateInThePostCompletionHookTest::FakeUser.new(HUMAN_ID)], ['Development::Doing']
      )
    end

    def merge_request(_path, _iid) = MrStateFixtures::FakeMr.new(@state, nil)
  end

  def setup
    setup_database
    GitlabHelpers.instance_variable_set(:@current_user_id, AUTODEV_ID)
  end

  def enqueued_for(state)
    create_issue(status: 'done', mr_iid: 42)
    dispatcher = Autodev::PollDispatcher.allocate
    { '@path' => PROJECT_CONFIG['path'], '@project_config' => PROJECT_CONFIG, '@config' => {},
      '@logger' => StubLogger.new, '@client' => StubClient.new(state) }
      .each { |name, value| dispatcher.instance_variable_set(name, value) }
    enqueued = []
    IssueProcessJob.stub(:perform_later, ->(*args) { enqueued << args }) do
      dispatcher.send(:dispatch_done_unassigned)
    end
    enqueued
  end

  # The bug, latent only because no project configures `post_completion` today:
  # `%w[merged closed]` did not include `locked`, so the hook — a deploy — ran
  # while GitLab was performing the merge.
  def test_a_locked_mr_does_not_run_the_deploy_hook
    assert_empty enqueued_for('locked'),
                 'post_completion ran on an MR GitLab was still merging'
  end

  def test_a_state_added_to_the_one_list_runs_nothing_here_either
    with_widened_list { assert_empty enqueued_for(FUTURE_TRANSIENT_STATE) }
  end

  # This reader's own decision, unchanged: the hook is for a delivered ticket
  # whose MR is still open, and neither ending qualifies.
  def test_an_open_mr_still_reaches_the_hook
    refute_empty enqueued_for('opened')
  end

  def test_a_merged_or_closed_mr_still_skips_the_hook
    assert_empty enqueued_for('merged')
    assert_empty enqueued_for('closed')
  end
end

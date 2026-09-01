# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/target_branch'

# Autodev #91, review round — the discriminant is "a merge request still carries
# this work", not "the `mr_iid` column is filled in".
#
# `TargetBranch.resolve` dispatched on `if mr_iid`, and `mr_iid` is a column
# `PollRouter::ResumeHandler#reenter_via_reimplementation` deliberately **keeps**
# when it re-arms a request whose merge request a human closed without merging.
# The next run of that request therefore asked GitLab for the target of a merge
# request that is over, and got a real answer — the branch that closed merge
# request was pointed at:
#
#   * the source branch still on the remote → `reuse = true` → the autodev branch
#     rebased onto the target of a **closed** merge request and force-pushed. That
#     is the damage Autodev #91 was filed against, reproduced by its own
#     discriminant, and it is worse here than in the case the ticket fixed:
#     `MrManager#find_existing_mr` filters `state: 'opened'`, so the merge request
#     the run then creates targets the *configuration*, which is not the branch
#     the work was just rebased onto;
#   * the source branch deleted → `reuse = false` → no fetch of that base, and
#     `verify_changes` asked `git log origin/<closed MR's target>..<branch>` on a
#     `--depth 1 --branch <config>` clone, which is single-branch. The ref is not
#     there, git answers non-zero, and the caller raised `No changes produced by
#     implementation` — a message about the implementation, on a request whose
#     implementation was never measured.
#
# Measured on production (01/09/2026): PowerPanne's 30 open merge requests all
# target `master`, which is what the configuration says, so nothing is live today.
# Four **closed** autodev merge requests target `staging`, which the configuration
# left behind on 25/08 — the population a reposed todo label walks straight into.
#
# So the question `of_merge_request` answers becomes "which target does the merge
# request that carries this work name", and a merge request that is over carries
# nothing. Autodev #72's `MrState` owns the vocabulary half, as it does for the
# four other readers of `mr.state`.
class OnlyAnOpenMergeRequestCarriesTheWorkTest < Minitest::Test
  CONFIG = { 'target_branch' => 'master' }.freeze
  MR_TARGET = 'staging'

  FakeMr = Struct.new(:iid, :state, :target_branch)
  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  class StubClient
    attr_reader :reads

    def initialize(state: 'opened', target: MR_TARGET, error: nil)
      @state = state
      @target = target
      @error = error
      @reads = 0
    end

    def merge_request(_path, iid)
      @reads += 1
      raise @error if @error

      FakeMr.new(iid, @state, @target)
    end
  end

  def api_error(code, klass = Gitlab::Error::ResponseError)
    klass.new(FakeResponse.new('boom', code, FakeRequest.new('https://gitlab.example', '/api/v4/x')))
  end

  def resolve(client)
    TargetBranch.resolve(42, client: client, project_path: 'group/project',
                             project_config: CONFIG) { 'repository-default' }
  end

  # --- the two states that carry no work -----------------------------------

  # The reentry population. The configuration is the right answer because the run
  # that follows will *create* a merge request, and `create_merge_request` writes
  # the configuration's value into it.
  def test_a_closed_merge_request_hands_the_question_back_to_the_configuration
    assert_equal 'master', resolve(StubClient.new(state: 'closed'))
  end

  def test_a_merged_merge_request_hands_the_question_back_to_the_configuration
    assert_equal 'master', resolve(StubClient.new(state: 'merged'))
  end

  # --- the states that do carry it -----------------------------------------

  def test_an_open_merge_request_still_answers_with_its_own_target
    assert_equal MR_TARGET, resolve(StubClient.new(state: 'opened'))
  end

  # `locked` is GitLab performing the merge — the one state of the four that
  # carries no *verdict* (Autodev #69/#72) and every bit of work. Reading it as
  # "over" would rebase a branch mid-merge onto the configuration's branch.
  def test_a_locked_merge_request_still_carries_the_work
    assert_equal MR_TARGET, resolve(StubClient.new(state: 'locked'))
  end

  # An allow-list, and in the opposite direction from `mr_state_concluded?`'s
  # deny-list, because the consequences are not symmetric: reading an unknown
  # state as "still carries the work" costs a rebase onto the branch GitLab is
  # diffing against, which is never damage. Reading an open one as "over" is the
  # whole of Autodev #91.
  def test_a_state_gitlab_has_not_invented_yet_still_carries_the_work
    assert_equal MR_TARGET, resolve(StubClient.new(state: 'some_future_state'))
  end

  # --- the merge request that is not there any more (constat 7) ------------

  # `Gitlab::Error::NotFound` inherits `ResponseError`, so it took the outage
  # route: `ApiUnavailableError` on every poll, forever, on a request nothing will
  # ever be able to read. A merge request that is gone carries no work either —
  # which is also the behaviour that predates Autodev #91, restored deliberately
  # rather than by omission.
  def test_a_merge_request_that_no_longer_exists_carries_nothing
    client = StubClient.new(error: api_error(404, Gitlab::Error::NotFound))

    assert_equal 'master', resolve(client)
  end

  # And the control that keeps it from being a fallback: a read that failed for
  # any *other* reason is still not a value (Autodev #67).
  def test_a_read_that_failed_still_refuses_to_answer
    error = assert_raises(ApiUnavailableError) { resolve(StubClient.new(error: api_error(500))) }

    assert_equal :merge_request_target, error.what
  end

  def test_a_transport_failure_still_refuses_to_answer
    client = StubClient.new(error: Errno::ECONNRESET.new('Connection reset by peer'))

    assert_raises(ApiUnavailableError) { resolve(client) }
  end

  # --- the shape of the answer ---------------------------------------------

  # `of_merge_request` answers `nil` for "no merge request carries this work", and
  # `resolve` is the only place that turns that into question 1 — so a caller
  # cannot get the configuration's branch back believing it asked GitLab.
  def test_the_absence_of_a_carrier_is_nil_rather_than_a_substitute
    assert_nil TargetBranch.of_merge_request(StubClient.new(state: 'closed'), 'group/project', 42)
  end

  # An open merge request that names no target is still an abort: GitLab answered,
  # and the answer is unusable.
  def test_an_open_merge_request_naming_no_target_still_aborts
    assert_raises(MissingTargetBranchError) do
      TargetBranch.of_merge_request(StubClient.new(target: ''), 'group/project', 42)
    end
  end

  # One read, not two: the state and the target come off the same merge request.
  def test_the_state_and_the_target_cost_one_request
    client = StubClient.new(state: 'closed')
    resolve(client)

    assert_equal 1, client.reads
  end
end

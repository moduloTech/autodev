# frozen_string_literal: true

require_relative 'test_helper'
require 'autodev/danger_claude_runner'
require 'autodev/mr_fixer'
require 'autodev/pipeline_monitor'

# Autodev #62 — a GitLab call that failed must not answer with a value.
#
# Autodev #56 fixed one instance of this family (the pipeline age bound firing
# behind a poll that never read a status). Three readers were left taking a
# degraded return value for a verdict, all three built on the same shape:
#
#     rescue Gitlab::Error::ResponseError
#       []            # or nil, or false
#     end
#
# `[]` is not "GitLab is down", it is "nothing was found" — and at every call
# site in this codebase "nothing was found" is the good news:
#
#   1. `fetch_unresolved_discussions` → `[]` reads as a clean MR, and
#      `green_post_review` turns that into the `no_discussions` guard and
#      delivers. An MR carrying unresolved review threads shipped as reviewed
#      because GitLab hiccuped, with no attention flag and no comment — the same
#      outcome as the 11/08/2026 incident, by another route and with nothing to
#      betray it. (It is also a standing candidate for the race
#      `DiscussionSnapshot` was added to chase: issue #11859 went `done` with
#      count = 0 while 12 threads were open.)
#   2. `fetch_failed_jobs` → `[]` reads as "nothing fails anymore", which
#      `InfraRecheck#current_pipeline_verdict` calls `:recovered` and re-arms a
#      row whose pipeline may still be red.
#   3. a danger-claude evaluation that never ran returns nil, the poll ends
#      normally having concluded nothing, and the #56 age bound could fire
#      behind it.
#
# The fix is structural, not per-call-site: `GitlabHelpers.answer` is the single
# conversion point from "GitLab did not answer" to `ApiUnavailableError`, so a
# failed read has no representation as data at all. Nothing is left for a caller
# to misread, the poll ends at the boundary rescue with the row untouched, and
# the *default* for a newly added API call — no rescue at all — is now the safe
# one.
#
# Each section below has its control: the same code path with GitLab answering
# must still reach the verdict it always reached.
#
# Section 5 is the source guard, and what it can and cannot prove is written out
# above `ALLOWED_SWALLOWS` (Autodev #73) rather than left for a reader to infer
# from a green run — which is how two declarations that were plainly false
# survived one.

# --- shared fixtures -------------------------------------------------------

module ApiFailureFixtures
  FakePipeline = Struct.new(:id, :status)
  FakeMr = Struct.new(:state, :head_pipeline)
  FakeNote = Struct.new(:resolvable, :resolved, :body)
  FakeDiscussion = Struct.new(:id, :notes)

  # Gitlab::Error::ResponseError builds its message from the real HTTP response;
  # this is the minimum surface it reads. The conversion point is narrow on
  # purpose, so a plain Gitlab::Error::Error would not exercise it.
  FakeRequest = Struct.new(:base_uri, :path)
  FakeResponse = Struct.new(:parsed_response, :code, :request)

  def api_error
    Gitlab::Error::ResponseError.new(
      FakeResponse.new('boom', 500, FakeRequest.new('https://gitlab.example', '/api/v4/x'))
    )
  end

  def unresolved_thread
    FakeDiscussion.new('open-thread', [FakeNote.new(true, false, 'please fix this')])
  end

  def resolved_thread
    FakeDiscussion.new('closed-thread', [FakeNote.new(true, true, 'done')])
  end

  # Behaves like Gitlab::PaginatedResponse: the real list is only visible
  # through auto_paginate.
  class FakePaginated
    def initialize(items) = @items = items
    def auto_paginate = @items
  end

  # A PipelineMonitor with the four collaborators `init_runner` sets, and silent
  # logs. Each section adds the stubs its own path needs on top.
  def bare_monitor(client)
    mon = PipelineMonitor.allocate
    mon.instance_variable_set(:@client, client)
    mon.instance_variable_set(:@project_path, 'group/project')
    mon.instance_variable_set(:@project_config, {})
    mon.instance_variable_set(:@config, {})
    %i[log log_error].each { |noop| mon.define_singleton_method(noop) { |*| nil } }
    mon
  end
end

# --- 1. an API error must never deliver an MR ------------------------------

# The gravest of the three: this is the only path whose degraded value ends in a
# delivery. `handle_green` on a post-review MR asks GitLab for the unresolved
# threads, and the answer decides between `done` and `fixing_discussions`.
class ApiFailureNeverDeliversTest < Minitest::Test
  include ApiFailureFixtures
  # `finalize_green_done` stamps `finished_at` through `Issue.where(...)`, so the
  # delivery control needs the real table behind it.
  include DatabaseTestHelper

  def setup = setup_database

  # Mirrors the real AASM machine on the one transition under test: the
  # `pipeline_green` event reads the `no_discussions` guard the caller stamped.
  class FakeIssue
    attr_reader :issue_iid, :mr_iid, :mr_url, :review_count, :issue_author_id,
                :checking_pipeline_since, :pipeline_poll_since, :id
    attr_accessor :_review_count_zero, :_review_count_over_zero, :_unresolved_discussions_empty

    def initialize(review_count: 1)
      @attrs = { status: 'checking_pipeline' }
      @review_count = review_count
      @issue_iid = 11_859
      @mr_iid = 42
      @mr_url = 'http://gitlab/mr/42'
      @issue_author_id = 7
      @checking_pipeline_since = 1.hour.ago
    end

    # rubocop:disable Naming/PredicateMethod -- mirrors AASM's bang event, which
    # returns whether the transition happened.
    def pipeline_green!
      @attrs[:status] = _unresolved_discussions_empty ? 'done' : 'fixing_discussions'
      true
    end
    # rubocop:enable Naming/PredicateMethod

    def update(hash)
      @attrs.merge!(hash)
      @pipeline_poll_since = hash[:pipeline_poll_since] if hash.key?(:pipeline_poll_since)
      @checking_pipeline_since = hash[:checking_pipeline_since] if hash.key?(:checking_pipeline_since)
      self
    end

    def status = @attrs[:status]
    def done? = status == 'done'
  end

  # One open MR with a green head pipeline; the discussions endpoint either
  # answers `threads` or fails the way GitLab fails.
  class StubClient
    attr_reader :discussion_calls

    def initialize(threads: [], error: nil)
      @threads = threads
      @error = error
      @discussion_calls = 0
    end

    def merge_request(_path,
                      _iid)
      ApiFailureFixtures::FakeMr.new('opened',
                                     ApiFailureFixtures::FakePipeline.new(215_229, 'success'))
    end

    def merge_request_discussions(_path, _iid, **_opts)
      @discussion_calls += 1
      raise @error if @error

      ApiFailureFixtures::FakePaginated.new(@threads)
    end
  end

  def poll(threads: [], error: nil)
    client = StubClient.new(threads: threads, error: error)
    sink = { labels: [], notify: [], reassigned: [], activity: [] }
    mon = bare_monitor(client)
    mon.define_singleton_method(:claude_available?) { true }
    mon.define_singleton_method(:snapshot) { |*| nil }
    stub_sinks(mon, sink)
    issue = FakeIssue.new
    mon.check(issue)
    [issue, sink, client]
  end

  # Every point at which the delivery leaves the process: the GitLab label, the
  # assignee, the issue comment and the activity log.
  def stub_sinks(mon, sink)
    mon.define_singleton_method(:log_activity) { |_issue, key, **vars| sink[:activity] << [key, vars] }
    mon.define_singleton_method(:apply_label_done) { |iid| sink[:labels] << iid }
    mon.define_singleton_method(:notify_localized) { |_iid, key, **vars| sink[:notify] << [key, vars] }
    mon.define_singleton_method(:reassign_to_author) { |issue| sink[:reassigned] << issue.issue_iid }
  end

  # The bug, end to end.
  def test_an_unreachable_discussions_endpoint_does_not_deliver
    issue, sink = poll(error: api_error)

    assert_equal 'checking_pipeline', issue.status, 'an unread discussion list must not deliver the MR'
    assert_empty sink[:labels] + sink[:notify] + sink[:reassigned],
                 'no label, no comment and no handback may follow a read that failed'
  end

  # The row is left exactly where the previous poll left it, activity note
  # included: `dispatch_pipelines` re-enqueues it next cycle, and a line appended
  # per poll would grow the GitLab note for as long as the outage lasts.
  def test_an_unreachable_discussions_endpoint_leaves_no_green_trace
    _issue, sink = poll(error: api_error)

    refute_includes sink[:activity].map(&:first), :pipeline_green
    refute_includes sink[:activity].map(&:first), :pipeline_green_done
  end

  # --- controls: GitLab answering must still reach both verdicts ----------

  def test_no_unresolved_thread_still_delivers
    issue, sink, client = poll(threads: [resolved_thread])

    assert_equal ['done', [11_859], [:done_nominal]],
                 [issue.status, sink[:labels], sink[:notify].map(&:first)]
    assert_equal 1, client.discussion_calls, 'the delivery verdict must be read, not assumed'
  end

  def test_an_unresolved_thread_still_routes_to_the_fixer
    issue, sink = poll(threads: [unresolved_thread])

    assert_equal 'fixing_discussions', issue.status
    assert_empty sink[:labels]
  end
end

# --- 2. an API error must not read as "the CI is back" ---------------------

# `recheck_infra_recovery` re-arms a row that was given up on an infra failure,
# and it re-arms it on `:recovered` — which `current_pipeline_verdict` returns
# for an empty failed-job list. `fetch_failed_jobs` returned exactly that on an
# API error, so a GitLab outage during a recheck read as "nothing fails anymore".
class ApiFailureIsNotARecoveryTest < Minitest::Test
  include ApiFailureFixtures

  class FakeIssue
    ISSUE_IID = 16_081
    MR_IID = 42

    def initialize = (@attrs = { infra_recheck_count: 0 })
    def update(hash) = (@attrs.merge!(hash) and self)
    def issue_iid = ISSUE_IID
    def mr_iid = MR_IID
    def infra_recheck_count = @attrs[:infra_recheck_count]
    def infra_recheck_at = @attrs[:infra_recheck_at]
  end

  class StubClient
    def initialize(jobs: [], error: nil)
      @jobs = jobs
      @error = error
    end

    def merge_request(_path,
                      _iid)
      ApiFailureFixtures::FakeMr.new('opened',
                                     ApiFailureFixtures::FakePipeline.new(9, 'failed'))
    end

    def pipeline_jobs(_path, _pid, **_opts)
      raise @error if @error

      @jobs
    end
  end

  def recheck(jobs: [], error: nil)
    mon = bare_monitor(StubClient.new(jobs: jobs, error: error))
    issue = FakeIssue.new
    [mon.recheck_infra_recovery(issue), issue]
  end

  def test_an_unreachable_jobs_endpoint_does_not_rearm_the_row
    reentered, = recheck(error: api_error)

    refute reentered, 'an unread job list must not read as a recovered pipeline'
  end

  # Same rule as `check_stagnation_and_fix`: a cycle that never looked must not
  # spend one of the bounded attempts, or an outage burns the whole budget.
  def test_an_unreachable_jobs_endpoint_does_not_burn_a_recheck_attempt
    _reentered, issue = recheck(error: api_error)

    assert_equal 0, issue.infra_recheck_count
    assert_nil issue.infra_recheck_at
  end

  # Control: a red pipeline whose only failures are `allow_failure` really has
  # nothing blocking left, and that still re-arms the row.
  def test_a_genuinely_empty_failed_job_list_still_rearms_the_row
    reentered, = recheck(jobs: [{ 'name' => 'flaky', 'status' => 'failed', 'allow_failure' => true }])

    assert reentered
  end
end

# --- 3. a danger-claude evaluation that never ran is not a verdict ---------

# The fourth path of the Autodev #56 family, identified during its implementation
# and left out of scope then. `interpret_eval_result` returns nil both when the
# evaluation says "not code-related" (a verdict — waiting is the answer, and the
# age bound may count the poll) and when the evaluation could not be performed at
# all (no verdict — the bound must stand down).
class FailedEvaluationIsInconclusiveTest < Minitest::Test
  include ApiFailureFixtures

  class FakeIssue
    ABANDONABLE = %w[checking_pipeline fixing_discussions].freeze

    attr_reader :issue_iid, :mr_iid, :mr_url, :review_count, :issue_author_id,
                :checking_pipeline_since, :pipeline_poll_since, :pipeline_retrigger_count,
                :stagnation_signatures, :branch_name, :id

    def initialize
      @attrs = { status: 'checking_pipeline' }
      @issue_iid = 15_894
      @mr_iid = 42
      @mr_url = 'http://gitlab/mr/42'
      @issue_author_id = 7
      @review_count = 1
      @pipeline_retrigger_count = 1 # already retriggered: never re-enter that branch
      @branch_name = 'autodev/15894'
      @checking_pipeline_since = 20.days.ago
    end

    # rubocop:disable Naming/PredicateMethod -- mirrors AASM's bang event.
    def abandon!
      return false unless ABANDONABLE.include?(status)

      @attrs[:status] = 'done'
      @checking_pipeline_since = nil
      true
    end
    # rubocop:enable Naming/PredicateMethod

    def update(hash)
      @attrs.merge!(hash)
      @stagnation_signatures = hash[:stagnation_signatures] if hash.key?(:stagnation_signatures)
      @pipeline_poll_since = hash[:pipeline_poll_since] if hash.key?(:pipeline_poll_since)
      @checking_pipeline_since = hash[:checking_pipeline_since] if hash.key?(:checking_pipeline_since)
      self
    end

    def status = @attrs[:status]
    def needs_attention = @attrs[:needs_attention]
    def attention_reason = @attrs[:attention_reason]
  end

  class StubClient
    def initialize(jobs:) = @jobs = jobs

    def merge_request(_path,
                      _iid)
      ApiFailureFixtures::FakeMr.new('opened',
                                     ApiFailureFixtures::FakePipeline.new(9, 'failed'))
    end

    def pipeline_jobs(_path, _pid, **_opts) = @jobs
  end

  UNCERTAIN_JOBS = [{ 'name' => 'build', 'stage' => 'build', 'status' => 'failed',
                      'allow_failure' => false, 'failure_reason' => 'script_failure' }].freeze

  # A whole poll on a 20-day-old watch, red pipeline, pre-triage uncertain, so
  # the fix path reaches the Claude evaluation. `eval_result` is what
  # danger-claude gave back.
  def poll(eval_result:)
    sink = { notify: [], labels: [] }
    mon = bare_monitor(StubClient.new(jobs: UNCERTAIN_JOBS))
    stub_fix_path(mon, eval_result)
    stub_give_up_sinks(mon, sink)
    issue = FakeIssue.new
    mon.check(issue)
    [issue, sink]
  end

  # Everything between the failed-job list and the evaluation is stubbed: the
  # clone, the log files and danger-claude itself. What is exercised is how the
  # evaluation's answer travels back to the age bound.
  def stub_fix_path(mon, eval_result)
    mon.define_singleton_method(:claude_available?) { true }
    mon.define_singleton_method(:log_activity) { |*, **| nil }
    mon.define_singleton_method(:pre_triage) { |_jobs| { verdict: :uncertain, explanation: nil } }
    mon.define_singleton_method(:prepare_work_dir) { |*| nil }
    mon.define_singleton_method(:write_and_categorize_jobs) { |*| [] }
    mon.define_singleton_method(:evaluate_code_related) { |*| eval_result }
    mon.define_singleton_method(:dispatch_fix) { |*| nil }
  end

  def stub_give_up_sinks(mon, sink)
    mon.define_singleton_method(:apply_label_done) { |iid| sink[:labels] << iid }
    mon.define_singleton_method(:notify_localized) { |_iid, key, **vars| sink[:notify] << [key, vars] }
    mon.define_singleton_method(:reassign_to_author) { |*| nil }
  end

  def test_a_crashed_evaluation_does_not_expire_the_watch
    issue, sink = poll(eval_result: nil)

    assert_equal 'checking_pipeline', issue.status,
                 'a poll whose evaluation never ran concluded nothing and must not give the ticket up'
    assert_empty sink[:notify] + sink[:labels], 'nothing may be announced about a give-up that did not happen'
  end

  # Control, and the distinction that matters: "the failure is not code-related"
  # IS a verdict. The poll read one, decided to wait, and a fortnight of that is
  # exactly what Autodev #53's bound exists to stop.
  def test_a_non_code_verdict_still_expires_the_watch
    issue, sink = poll(eval_result: { 'code_related' => false, 'explanation' => 'runner died' })

    assert_equal ['done', true, 'pipeline_watch_expired'],
                 [issue.status, issue.needs_attention, issue.attention_reason]
    refute_empty sink[:notify]
  end
end

# --- 4. the second copy: MrFixer -----------------------------------------

# MrFixer's `fetch_unresolved_discussions` had the same `rescue → []`. It does
# not deliver — it sends the row back to `checking_pipeline` — but it announces
# "no unresolved discussions", resets the retrigger counter and burns a round on
# an MR it never read.
class MrFixerApiFailureTest < Minitest::Test
  include ApiFailureFixtures

  class FakeIssue
    attr_reader :issue_iid, :mr_iid, :fix_round, :attrs

    def initialize
      @issue_iid = 11_859
      @mr_iid = 42
      @fix_round = 0
      @attrs = { status: 'fixing_discussions' }
    end

    def update(hash) = (@attrs.merge!(hash) and self)
    def discussions_fixed! = @attrs[:status] = 'checking_pipeline'
    def status = @attrs[:status]
  end

  class StubClient
    def initialize(threads: [], error: nil)
      @threads = threads
      @error = error
    end

    def merge_request_discussions(_path, _iid, **_opts)
      raise @error if @error

      ApiFailureFixtures::FakePaginated.new(@threads)
    end
  end

  def run_fix(threads: [], error: nil)
    activity = []
    fixer = bare_fixer(StubClient.new(threads: threads, error: error), activity)
    issue = FakeIssue.new
    fixer.fix(issue)
    [issue, activity]
  end

  def bare_fixer(client, activity)
    MrFixer.allocate.tap do |fixer|
      fixer.instance_variable_set(:@client, client)
      fixer.instance_variable_set(:@project_path, 'group/project')
      fixer.instance_variable_set(:@logger, StubLogger.new)
      %i[log log_error].each { |noop| fixer.define_singleton_method(noop) { |*| nil } }
      fixer.define_singleton_method(:log_activity) { |_issue, key, **vars| activity << [key, vars] }
      fixer.define_singleton_method(:execute_fix_cycle) { |*| nil }
    end
  end

  def test_an_unreachable_discussions_endpoint_does_not_end_the_round
    issue, activity = run_fix(error: api_error)

    assert_equal 'fixing_discussions', issue.status, 'the row must wait for the next cycle'
    refute_includes activity.map(&:first), :discussions_none
  end

  def test_an_unreachable_discussions_endpoint_leaves_no_round_trace
    _issue, activity = run_fix(error: api_error)

    assert_empty activity, 'a round that could not read the MR must leave the note as it was'
  end

  # Control: a genuinely clean MR still goes back to the pipeline watch.
  def test_a_genuinely_clean_mr_still_ends_the_round
    issue, activity = run_fix(threads: [resolved_thread])

    assert_equal 'checking_pipeline', issue.status
    assert_includes activity.map(&:first), :discussions_none
  end

  def test_an_unresolved_thread_still_reaches_the_fix_cycle
    issue, activity = run_fix(threads: [unresolved_thread])

    assert_equal 'fixing_discussions', issue.status
    assert_includes activity.map(&:first), :discussions_found
  end
end

# --- 5. the shape itself -------------------------------------------------

# (b) In the pipeline-monitor / MR-fixer tree, every place a GitLab error stops
# travelling is declared below with the reason its substitute cannot be mistaken
# for an answer. Everywhere else the error must reach a boundary — which is what
# `GitlabHelpers.answer` guarantees for a wrapped read, and what a bare
# `@client.…` call with no rescue at all already does for free.
#
# That is the whole of the ticket's criterion. The failure mode of Autodev #62 was
# not that somebody wrote a bad rescue; it was that the rescue looked exactly like
# every other line around it, in four places, and nothing made a reviewer ask what
# the substitute would be read as. Adding one now means editing this list, in the
# same commit, with a sentence.
#
# ## What this list proves, and what it does not (Autodev #73)
#
# What is checked mechanically: that a clause catching a failed read exists, that
# the method holding it is named here, and — since #73 — that the clause does not
# get credit for a `raise` of some *other* class. That is all.
#
# The value in the hash is an **English sentence, and nothing verifies it**. It is
# a declaration of intent by whoever added the entry, not a proof, and the
# difference is not academic: two entries in this very list said "no read inside"
# while an unprotected `client.issue` sat underneath them (`attempt_fix` and
# `execute_fix_cycle`, the whole of Autodev #67), and this file was green
# throughout — through a review, and through the ticket that wrote the sentence.
# Both now say "audited, not assumed" and enumerate what they audited, which is
# the strongest form available here: an inventory a reader can re-walk, not a
# claim a test can re-check.
#
# So read a green run as "every swallow is declared", never as "every declaration
# is true". When you touch a method named here, re-read its sentence against the
# code and correct it in the same commit — that re-reading is the only mechanism
# this half of the guard has.
#
# Two forms are out of reach and are stated rather than hidden:
#
#   * a `rescue Exception` — `Exception` is not in `NAMED`, so a clause naming it
#     would look like it catches nothing relevant. Theoretical: RuboCop's
#     `Lint/RescueException` is enabled for this project and refuses the form, so
#     it cannot reach master without a disable comment naming the cop.
#   * a *file-level* `rubocop:disable Style/RescueModifier` block, which has no
#     enclosing method for the directive half of the modifier rule below to
#     attribute. `SwallowScanner` still sees the modifier itself, which is why the
#     two live side by side.
ALLOWED_SWALLOWS = {
  'lib/autodev/pipeline_monitor.rb' => {
    # The boundary of one poll: the whole point is that the failure stops here,
    # with the row untouched and `abandon_expired_watch` unreached.
    'check' => 'poll boundary'
  },
  'lib/autodev/mr_fixer.rb' => {
    # The boundary of one fix round, for the same reason — and so the exception
    # does not reach ActiveJob and park the row in Solid Queue's failed
    # executions, which needs a human for something the next cycle retries.
    'fix' => 'fix-round boundary',
    # A write. Failing to mark a thread resolved leaves it unresolved, which the
    # next round re-reads. No verdict is inferred from the failure.
    'resolve_discussion' => 'write, not a read'
  },
  'lib/autodev/mr_fixer/fix_cycle.rb' => {
    # Clone, rebase, danger-claude, push. `fetch_unresolved_discussions` is
    # performed by `MrFixer#fix` *before* calling in here, on purpose, and the
    # prompt-context read inside `prepare_fix_environment` now raises
    # `ApiUnavailableError`, which this method re-raises above its two handlers
    # (Autodev #67 — it used to be swallowed here and imputed to the fix).
    #
    # Audited, not assumed, and re-audited for Autodev #91, which added a read
    # under this method: `target_branch_for` → `TargetBranch.of_merge_request` →
    # `client.merge_request`, asked between the clone and the rebase because the
    # base the branch is rebased onto is the target that merge request carries.
    # It goes through `GitlabHelpers.answer`, so it raises `ApiUnavailableError`
    # and leaves through the same re-raise as the prompt-context read — nothing
    # is rebased, nothing is force-pushed, and `fix_round` is not advanced.
    #
    # The rest of the GitLab traffic left under this method is
    # `resolve_discussion` (a write, declared below), `ScreenshotUploader.process`
    # (uploads, own rescues) and `log_activity` / `notify_localized`, which
    # swallow their own failures because a note that could not be edited is not
    # a verdict either.
    'execute_fix_cycle' => 'fix-round boundary: clone, rebase, danger-claude, push'
  },
  'lib/autodev/mr_fixer/stagnation_checker.rb' => {
    # `JSON.parse(issue.stagnation_signatures || '{}') rescue {}` — the rescue
    # *modifier*, which the scanner could not see until Autodev #67. Honest and
    # trivial: the input is a column this same method wrote, the call is local,
    # there is no GitLab read anywhere underneath, and `{}` means "start the
    # signature history over", which costs one extra fix round at worst.
    #
    # Declared rather than deleted because the form is the hazard, not this
    # instance: it is the shape a reader reproduces by imitating the line above,
    # and it sat one directory from the delivery path with its own
    # `rubocop:disable` comment ready to copy.
    'discussion_stagnated?' => 'local JSON.parse of a column we wrote, not a read'
  },
  'lib/autodev/pipeline_monitor/post_completion.rb' => {
    # Two more rescue modifiers the scanner was blind to. `Process.kill('KILL', -pid)`
    # and `Process.wait(pid)` on a process group that already died raise
    # `Errno::ESRCH` / `Errno::ECHILD`, and "it is already gone" is the outcome
    # this method wants. No GitLab call, no verdict.
    'kill_process' => 'local process signalling, not a read'
  },
  'lib/autodev/mr_fixer/discussion_formatter.rb' => {
    # `git diff` in a work directory, for the prompt. No GitLab call, and the
    # substitute (`nil` = no diff hunk to quote) removes context from a prompt
    # rather than answering a question.
    'extract_diff_hunk' => 'local git, not a read'
  },
  'lib/autodev/pipeline_monitor/infra_recheck.rb' => {
    # The boundary of one recheck. `false` means "do not re-enter", which is the
    # conservative answer and the one the caller wants when nothing was read.
    'recheck_infra_recovery' => 'recheck boundary'
  },
  'lib/autodev/pipeline_monitor/failure_handler.rb' => {
    # A write. `false` means "the pipeline was not retriggered", which is exactly
    # what happened; the caller falls through to the triage it would have run.
    'retrigger_if_needed' => 'write, not a read',
    # Everything from the triage onwards: clone, danger-claude, push. `handle_red`
    # reads the failed jobs *before* calling in here — that hoist is Autodev #62's.
    #
    # The prompt-context read underneath (`build_fix_context_hash` →
    # `GitlabHelpers.fetch_full_context`) was the gap #62 left and Autodev #67
    # closed. It could not be hoisted out of here the way the job list was — it
    # needs the clone's work directory, for the ticket's images — so instead it
    # raises `ApiUnavailableError` and this method re-raises it above its two
    # handlers, and `dispatch_fix` performs it *before* `pipeline_failed_code!` so
    # the abort leaves the row in `checking_pipeline`. The stagnation counter is
    # written *after* `clone_and_fix` returns (Autodev #71), so the abort leaves
    # that column untouched too — it used to be written before, which let a
    # selective outage on the issue endpoint spend the whole stagnation budget
    # without a single correction being attempted.
    #
    # Audited, not assumed, and re-audited for Autodev #91, which added a read
    # under this method too: `prepare_work_dir` asks `target_branch_for` for the
    # base before it rebases, which reads `client.merge_request` through
    # `GitlabHelpers.answer`. Same route out as the prompt-context read, and the
    # stagnation signature is written after `clone_and_fix` returns, so the abort
    # spends nothing.
    #
    # The rest of the GitLab traffic left under this method is `retry_pipeline`
    # and `fetch_job_trace` (both declared here) plus the label / assignee / note
    # writes of `abandon_issue`, `log_activity` and `notify_localized`, each of
    # which swallows its own failure.
    'attempt_fix' => 'fix boundary: clone, danger-claude, push'
  },
  'lib/autodev/pipeline_monitor/reviewer.rb' => {
    # mr-review is a subprocess, not a GitLab call. A crash is already non-fatal
    # by design (`false` = review not performed, the round is not counted), and
    # Autodev #49 made the diagnostic survive it.
    'execute_mr_review' => 'subprocess, not a read'
  },
  'lib/autodev/poll_router.rb' => {
    # The boundary of one issue's routing (Autodev #67). Per issue rather than
    # per pass on purpose: raised any higher the error lands in
    # `PollDispatcher#dispatch`'s own `rescue StandardError` and one unreadable
    # MR takes the whole project's cycle down with it — pipeline checks,
    # discussion fixes and retries included.
    'route' => 'routing boundary for one issue'
  },
  'lib/autodev/pipeline_monitor/api_helpers.rb' => {
    # The one read still allowed to substitute. The substitute names itself in the
    # value ("(trace unavailable: …)"), it is written into a log file for a human
    # or for Claude to read as prose rather than compared against anything, and one
    # unreadable trace must not abandon the fix of the jobs whose traces arrived.
    'fetch_job_trace' => 'self-describing prose, not a verdict'
  },
  'lib/autodev/pipeline_monitor/skill_reviewer.rb' => {
    # No GitLab read sits under this method at all: `clone_and_checkout` is a
    # local `git clone` (raising `GitError` on failure) and `SkillsInjector.inject`
    # never calls the API (an untyped `Errno::*` from its own `File.write` /
    # `FileUtils.mkdir_p` is the failure being normalised here). The reclass to
    # `ImplementationError` is deliberate, not a value standing in for an unread
    # verdict: `review_with_skill`'s own rescue already treats that class as a
    # review failure (Autodev #74) — judgment never started on a clone or
    # injection failure, so there is nothing to retry differently. A GitLab error
    # from `ReviewPublisher#publish`, called later in the same method chain, is a
    # different class (`ApiUnavailableError`) and is untouched by this rescue —
    # it keeps propagating past `review_with_skill`, exactly what this entry does
    # not cover.
    'clone_and_inject' => 'reclass to a review failure; no GitLab read underneath'
  }
}.freeze

# Line-by-line walk of one file, collecting the names of the methods whose
# `rescue` of a GitLab error does not re-raise. Deliberately textual: what it
# checks is a property of the source a reader sees, and the point is to make the
# list above the only place the exceptions live.
class SwallowScanner
  # A clause counts when it *can catch* a failed read, not when it happens to
  # name one. `ApiUnavailableError < AutodevError < StandardError`, so a
  # `rescue StandardError` swallows it just as thoroughly as a clause naming it
  # — and it is the more likely way to reintroduce Autodev #62, because it does
  # not look like it has anything to do with GitLab. A bare `rescue` and
  # `rescue => e` are StandardError spelled shorter. Clauses that name an
  # unrelated class (`RateLimitError`, `JSON::ParserError`) cannot catch a
  # failed read and are ignored.
  NAMED = /^\s*rescue\s+.*(Gitlab::Error|ApiUnavailableError|AutodevError|StandardError)/
  CATCH_ALL = /^\s*rescue\s*(=>|$|#|\z)/
  # `expr rescue fallback` — the modifier form, and the second blind spot
  # Autodev #67 closed. It is `rescue StandardError` spelled with no `rescue`
  # *line* at all, so the two anchored patterns above cannot see it: something
  # precedes it on the line. It is also a whole clause on one line — the
  # substitute is right there — hence its own branch in `step`.
  MODIFIER = /\S\s+rescue\s+\S/
  CLAUSE_END = /^\s*(end|def|rescue|ensure)\b/
  # A clause re-raises when it puts *the same* exception back on its way to the
  # boundary: bare `raise` (which re-raises `$!` untouched) or `raise <local>`
  # (the variable the clause captured). This used to be `/\braise\b/` — the word
  # anywhere in the clause — and that is the third blind spot of this scanner
  # (Autodev #73), the one with a live symptom rather than a hypothetical one:
  #
  #     rescue StandardError => e
  #       raise ImplementationError, e.message
  #
  # counted as a re-raise, and it is not one. `ImplementationError` is not an
  # `ApiUnavailableError`, so it does not travel to `PipelineMonitor#check` or
  # `MrFixer#fix` — it falls into the `rescue StandardError` of the *fix*
  # boundary one frame up, which marks the ticket `error` and posts a comment
  # blaming the correction. That is precisely the outcome Autodev #67 removed for
  # the prompt-context read, reachable again by a form the guard called safe.
  RERAISE = /\braise(?:\s+[a-z_]\w*)?\s*(?:$|#)/
  # `raise SomeError, …` / `raise SomeError.new(…)` — a new exception of a
  # *different* class. Reported as its own kind rather than lumped in with the
  # swallows, because the fix is not the same: a swallow needs the rescue taken
  # out, a re-class needs the class it raises to be one the boundary above
  # recognises (`GitlabHelpers.answer`'s `ApiUnavailableError` is the legitimate
  # shape of this — a conversion that keeps travelling — which is why the form is
  # declarable rather than banned).
  RECLASS = /\braise\s+(?:::)?[A-Z]\w*/
  RECLASS_NOTE = ' (re-raises a different class)'
  METHOD_DEF = /^\s*def\s+([a-z_][\w?!]*)/
  # What the scanner reads is *code*. Strings go first (so removing comments
  # cannot cut a `#` out of the middle of a literal), comments second. Both
  # blind spots this handles are the same mistake in two directions: a log
  # message containing the word "raise" made a clause look like a re-raise —
  # `RERAISE` was applied after stripping comments but not strings — and the
  # same text could equally invent a `rescue` where the code has none.
  STRING = /"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/
  COMMENT = /#.*/

  def self.code_of(line) = line.gsub(STRING, '""').sub(COMMENT, '')

  def initialize(lines)
    @lines = lines
    @found = []
    @clause = nil
    @method = nil
  end

  # `[method_name, kind]` pairs, `kind` being `:swallow` (the clause substitutes
  # a value) or `:reclass` (it raises a different class, which reaches a
  # different handler than the one the rule is about).
  def swallowing_methods
    @lines.each { |line| step(self.class.code_of(line)) }
    close_clause
    @found
  end

  private

  def step(code)
    close_clause if @clause && code.match?(CLAUSE_END)
    @method = ::Regexp.last_match(1) if code =~ METHOD_DEF
    return record_modifier(code) if code.match?(MODIFIER)
    return open_clause if catches_failed_read?(code)

    note_raise(code)
  end

  def open_clause = @clause = { method: @method, reraises: false, reclasses: false }

  def note_raise(code)
    return unless @clause

    @clause[:reraises] = true if code.match?(RERAISE)
    @clause[:reclasses] = true if code.match?(RECLASS)
  end

  # One line, one whole clause. `x = f rescue raise` re-raises; anything else —
  # a value, or an exception of another class — substitutes.
  def record_modifier(code)
    @found << [@method, :swallow] unless code.sub(MODIFIER, ' rescue ').match?(RERAISE)
  end

  def catches_failed_read?(code)
    code.match?(NAMED) || code.match?(CATCH_ALL)
  end

  def close_clause
    return unless @clause

    @found << [@clause[:method], @clause[:reclasses] ? :reclass : :swallow] unless @clause[:reraises]
    @clause = nil
  end
end

# The ticket's own criterion: the next GitLab call added must not be able to
# reproduce the defect unnoticed. Two things carry that, and both are pinned
# here rather than left to the next reviewer's memory.
class DegradedApiValueShapeTest < Minitest::Test
  # (a) There is ONE definition of "the unresolved threads of an MR". There were
  # two, identical bar the return shape, and only one of them was on the
  # delivery path — so fixing that one would have left the other free to grow
  # the bug back at the next copy-paste.
  def test_both_callers_share_one_definition_of_the_unresolved_threads
    assert_equal MrDiscussions, MrFixer.instance_method(:fetch_unresolved_discussions).owner
    assert_equal MrDiscussions, PipelineMonitor.instance_method(:fetch_unresolved_discussions).owner
  end

  # The perimeter is **deliberately restricted, and this is the reason** (Autodev
  # #67 — before it, the restriction was simply where #62's diff happened to
  # stop). What is scanned is the code that takes a decision *and acts on it from
  # a read*: the pipeline watch and the MR fix round (a delivery, a give-up, a
  # re-arm), and since #67 the reentry decision, whose substitute was the most
  # expensive branch autodev has — a full clone + danger-claude + push on a ticket
  # whose MR may already be merged.
  #
  # It is not "everything that talks to GitLab", and the omissions were checked
  # one by one rather than assumed:
  #
  #   * `IssueNotifier`, `LabelManager`, `ActivityLogger`, `ScreenshotUploader`,
  #     `ExternalState#notify_stop` — writes. A note that could not be posted or a
  #     label that could not be set reports what happened; it invents nothing.
  #     #62 scopes writes out explicitly.
  #   * `PollDispatcher#check_external_state` / `#check_post_completion_needed`,
  #     `DormantAudit#audit`, `LabelHandover#events` — the rescue already sits at
  #     the unit-of-work boundary and its substitute means "do not act on this row
  #     this cycle", which is what the rule prescribes. `DormantAudit` bumps its
  #     counter *before* the read, deliberately, so an unreachable project burns
  #     the cap instead of being retried forever.
  #   * `IssueProcessor` — an active row mid-flight, where "conclude nothing and
  #     re-read next cycle" has no mechanism: no pass selects the pre-MR states
  #     (`cloning` … `creating_mr`). `dispatch_pipelines` and `dispatch_discussions`
  #     do re-enqueue their own active states, which is why the two fix boundaries
  #     above can afford to conclude nothing.
  #     `error` + `next_retry_at` is the re-arming path there, and it is bounded.
  #   * `DiscussionSnapshot` — instrumentation, which swallows everything by
  #     design so it can never break what it is instrumenting.
  #
  # Widening the perimeter to those would make the list a catalogue of writes and
  # drown the four entries that matter. Re-read this paragraph before adding a
  # file, and add the file if the reason no longer holds.
  SCANNED = %w[
    lib/autodev/pipeline_monitor.rb lib/autodev/mr_fixer.rb lib/autodev/mr_discussions.rb
    lib/autodev/poll_router.rb
  ].freeze

  SCANNED_DIRS = %w[lib/autodev/pipeline_monitor lib/autodev/mr_fixer lib/autodev/poll_router].freeze

  def test_every_swallowed_gitlab_error_in_the_delivery_path_is_declared
    undeclared = scanned_files.flat_map { |rel, abs| undeclared_swallows(rel, abs) }

    assert_empty undeclared, <<~MSG
      A GitLab error is caught and not re-raised here: #{undeclared.join(', ')}.

      Some caller will read whatever it returns instead as an answer — Autodev #62.
      Let it raise (GitlabHelpers.answer is the conversion point), or declare the
      method in ALLOWED_SWALLOWS with the reason its substitute cannot be mistaken
      for a verdict. "(re-raises a different class)" is the same rule for a clause
      doing `raise SomethingElse, e.message`: that class reaches the handler next
      door, the one that blames the correction, not the poll boundary (see RECLASS).
    MSG
  end

  # (c) The same rule again, stated without a regex: `Style/RescueModifier` is
  # enabled for this project, so RuboCop makes every `expr rescue fallback` carry
  # a disable comment naming that cop on its line, and grepping for it lands each
  # modifier in a declared method. Read as a second opinion, not as a complete
  # one: a `todo` spelling is matched below, but a *file-level* disable block has
  # no enclosing method and slips past this assertion. The scanner above catches
  # both forms, which is why the two live side by side.
  #
  # It exists because the modifier form is the one shape a reader is most likely
  # to reproduce by imitation — `StagnationChecker` already has one, comment
  # included, one file away from the delivery path — and because it says the rule
  # in a sentence instead of in `SwallowScanner`'s regexes. The scanner catches it
  # too; two independent statements of one rule is the point, not redundancy.
  # `todo` is the same directive under another name; RuboCop honours both.
  RESCUE_MODIFIER_DIRECTIVE = %r{rubocop:(?:disable|todo)\s+.*Style/RescueModifier}
  def test_every_inline_rescue_in_the_delivery_path_is_declared
    undeclared = scanned_files.flat_map { |rel, abs| undeclared_modifiers(rel, abs) }

    assert_empty undeclared, <<~MSG
      An `expr rescue fallback` sits in a method that is not declared in
      ALLOWED_SWALLOWS: #{undeclared.join(', ')}.

      The modifier form catches StandardError, so it catches a failed read, and it
      is the easiest one to write by imitating the line above it. Declare the
      method with the reason its substitute is safe, or take the rescue out.
    MSG
  end

  private

  def undeclared_swallows(rel, abs)
    reject_declared(rel, SwallowScanner.new(File.readlines(abs)).swallowing_methods)
  end

  # `[method, kind]`, so the diagnostic says which of the two problems it is.
  def format_finding(rel, method, kind)
    "#{rel}##{method}#{SwallowScanner::RECLASS_NOTE if kind == :reclass}"
  end

  # The directive-based half of the modifier rule (see the test above). The
  # method a directive belongs to is the last `def` at or above its line.
  def undeclared_modifiers(rel, abs)
    lines = File.readlines(abs)
    owners = lines.each_index
                  .select { |i| lines[i].match?(RESCUE_MODIFIER_DIRECTIVE) }
                  .map { |i| enclosing_method(lines, i) }
    reject_declared(rel, owners.compact.map { |method| [method, :swallow] })
  end

  def enclosing_method(lines, idx)
    lines[0..idx].reverse_each do |line|
      return ::Regexp.last_match(1) if line =~ SwallowScanner::METHOD_DEF
    end
    nil
  end

  def reject_declared(rel, findings)
    findings.reject { |method, _kind| ALLOWED_SWALLOWS.fetch(rel, {}).key?(method) }
            .map { |method, kind| format_finding(rel, method, kind) }
  end

  def scanned_files
    root = File.expand_path('..', __dir__)
    rels = SCANNED + SCANNED_DIRS.flat_map do |dir|
      Dir[File.join(root, dir, '*.rb')].map { |abs| abs.delete_prefix("#{root}/") }
    end
    rels.map { |rel| [rel, File.join(root, rel)] }
  end
end
